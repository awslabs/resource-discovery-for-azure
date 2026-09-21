#Requires -Version 7.0
<#
    Shared implementation for FindResource.ps1.

    Purpose: answer "which subscriptions in this scan contain resource type X,
    and how big is it" from ALREADY-PRODUCED report output. No Azure calls.

    Why this exists: a resource type can be collected into Inventory_*.json but
    not yet handled by server ingestion, so the only copy of that data is the
    report bundle itself. Each per-subscription HTML report covers ONE
    subscription, so there is no single report to search across an estate. This
    walks every bundle instead and returns the matching rows.

    Efficiency note: a per-subscription zip is dominated by Consumption_*.csv
    (megabytes), while Inventory_*.json is a few kilobytes of it. Every read here
    therefore opens the zip and pulls ONLY the inventory entry, rather than
    extracting the archive.

    PII note: de-obfuscated reports are excluded at SELECTION time, never by
    member name. The reveal engine renames only the OUTER zip *_revealed.zip and
    rewrites the inner html/json members IN PLACE, so those members keep ordinary
    names and a member-name filter alone would let real data through. The same
    guard exists in Invoke-RdaReveal (Reveal.ps1), in
    New-RdaAllSubHtmlSummaryFromZip (AllSubHtmlSummary.Functions.ps1) and in the
    per-sub html pick in Run-AllSubscriptions.ps1. Cited by function rather than
    by line number, because a line citation for a P0 guard rots silently. Note
    those siblings match a file NAME; this file matches a FULL PATH, which is
    stricter because it also catches a *_revealed parent folder.

    Absence claims: this tool exists to answer "is type X anywhere in this
    estate", so a wrong "no" is its worst possible output. Two rules follow.
    First, coverage is tracked as SETS OF REPORT IDS, never as counters: a
    counter can be inflated past its own denominator by duplicate input or a
    subscription read twice, which would turn partial coverage into an apparent
    complete one. Sets make that arithmetically impossible. Second, anything the
    scan did not cover - a missing path, a refused path, an unreadable subtree, a
    skipped bundle, a failed read - is recorded and forces the summary off the
    "confirmed zero" wording. See Get-RdaTypeCoverage and Write-RdaFindSummary.

    Load-order contract: Write-RdaProgress lives in Functions/Common.Functions.ps1.
    Dot-source that first for progress reporting. Its absence is tolerated (the
    call is guarded, as Invoke-RdaReveal does), so a caller that only wants the
    data need not load it.
#>

$Script:RdaRevealedExclusion = '*revealed*'

$Script:RdaReportStampPattern = '(\d{15,}[0-9a-fA-F]{0,4})(?=\.|$|_)'

function Assert-RdaRevealedExclusion
{
    <#
    .SYNOPSIS
        Fail closed if the de-obfuscated-report exclusion pattern is missing.
    #>
    [CmdletBinding()]
    param([string]$Pattern)

    if ([string]::IsNullOrWhiteSpace($Pattern))
    {
        throw 'The de-obfuscated-report exclusion pattern is unset. Refusing to scan, because without it a revealed report carrying real identifiers would be read as an ordinary source.'
    }
}

function Get-RdaReportId
{
    <#
    .SYNOPSIS
        Extract the run/report stamp that identifies one subscription's report.
    .DESCRIPTION
        Every artifact for a single subscription's report shares one numeric
        stamp, so Inventory_ResourcesReport_<stamp>.json and
        ResourcesReport_<stamp>.zip both yield <stamp>. That is what lets the SAME
        report reached two different ways (a loose json and the zip beside it) be
        recognised as one subscription instead of counted twice.

        Returns the file's base name when no stamp is present, so an unexpected
        name still de-duplicates against itself rather than throwing. Consequence
        worth knowing, because de-duplication depends entirely on this key: two
        DIFFERENTLY named stamp-less files never de-duplicate against each other,
        so hand-renamed copies of one report would both be counted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $Match = [regex]::Match($Name, $Script:RdaReportStampPattern)
    if ($Match.Success) { return $Match.Groups[1].Value }
    return [System.IO.Path]::GetFileNameWithoutExtension($Name)
}

function Get-RdaSourceKindRank
{
    <#
    .SYNOPSIS
        Sort rank for de-duplication, preferring the cheapest read.
    .DESCRIPTION
        An unknown kind sorts LAST. A bare hashtable lookup would return $null,
        and $null orders BEFORE 0 in a Sort-Object key position, so an unexpected
        kind would win de-duplication over a LooseJson, the opposite of the
        intent. Keeping the ordering total by construction avoids that.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][string]$Kind)

    switch ($Kind)
    {
        'LooseJson' { return 0 }
        'PerSubZip' { return 1 }
        'ConsolidatedZip' { return 2 }
        default { return [int]::MaxValue }
    }
}

function Get-RdaInventorySource
{
    <#
    .SYNOPSIS
        Discover every per-subscription inventory reachable under the given paths.
    .DESCRIPTION
        Classifies what it finds into three source kinds, so the caller does not
        need to know how a given scan was delivered:

          LooseJson       an Inventory_*.json sitting in an extracted report folder
          PerSubZip       a ResourcesReport*.zip holding one subscription's report
          ConsolidatedZip an AllSubscriptions_*/shard-*.zip holding many per-sub zips

        Discovery is recursive and driven by FILE NAME, not by folder layout, so a
        sharded scan (shard-NofM-AllSubscriptions_*/ResourcesReport_*.zip) is found
        without depending on the shard naming convention.

        Results are de-duplicated on report stamp, preferring the cheapest read,
        with a secondary key on full path so an equal-rank collision resolves
        reproducibly instead of arbitrarily.

        NOTHING is dropped silently. Every path not covered lands in one of four
        lists - Missing, Rejected (includes every de-obfuscated report excluded by
        the PII guard), Unreadable, Skipped - because the caller uses all four to
        decide whether it is entitled to call a zero a confirmed absence.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Path)

    Assert-RdaRevealedExclusion -Pattern $Script:RdaRevealedExclusion
    $Excl = $Script:RdaRevealedExclusion

    $Sources = [System.Collections.Generic.List[object]]::new()
    $Missing = [System.Collections.Generic.List[string]]::new()
    $Unreadable = [System.Collections.Generic.List[string]]::new()
    $Rejected = [System.Collections.Generic.List[string]]::new()
    $Skipped = [System.Collections.Generic.List[string]]::new()

    $RefuseRevealed = {
        param([string]$FullName)
        '{0} (de-obfuscated report, refused by the PII guard: it carries real identifiers)' -f $FullName
    }

    foreach ($P in $Path)
    {
        $Item = $null
        try
        {
            $Item = Get-Item -LiteralPath $P -ErrorAction Stop
        }
        catch [System.Management.Automation.ItemNotFoundException]
        {
            $Missing.Add($P)
            continue
        }
        catch
        {
            $Unreadable.Add(('{0}: {1}' -f $P, $_.Exception.Message))
            continue
        }

        if (-not $Item.PSIsContainer)
        {
            if ($Item.FullName -like $Excl)
            {
                $Rejected.Add((& $RefuseRevealed $Item.FullName))
            }
            elseif ($Item.Name -like 'Inventory_*.json')
            {
                $Sources.Add([pscustomobject]@{ Kind = 'LooseJson'; File = $Item.FullName })
            }
            elseif (($Item.Name -like 'AllSubscriptions_*.zip') -or ($Item.Name -like 'shard-*.zip'))
            {
                $Sources.Add([pscustomobject]@{ Kind = 'ConsolidatedZip'; File = $Item.FullName })
            }
            elseif ($Item.Name -like '*ResourcesReport*.zip')
            {
                $Sources.Add([pscustomobject]@{ Kind = 'PerSubZip'; File = $Item.FullName })
            }
            else
            {
                $Rejected.Add(('{0} (not a report artifact; expected Inventory_*.json, ResourcesReport*.zip, AllSubscriptions_*.zip or shard-*.zip)' -f $Item.FullName))
            }
            continue
        }

        $BeforeCount = $Sources.Count

        $EnumErrors = @()

        foreach ($Found in Get-ChildItem -LiteralPath $Item.FullName -Recurse -File -Filter 'Inventory_*.json' -ErrorAction SilentlyContinue -ErrorVariable +EnumErrors)
        {
            if ($Found.FullName -like $Excl) { $Rejected.Add((& $RefuseRevealed $Found.FullName)); continue }
            $Sources.Add([pscustomobject]@{ Kind = 'LooseJson'; File = $Found.FullName })
        }

        foreach ($Found in Get-ChildItem -LiteralPath $Item.FullName -Recurse -File -Filter '*ResourcesReport*.zip' -ErrorAction SilentlyContinue -ErrorVariable +EnumErrors)
        {
            if ($Found.FullName -like $Excl) { $Rejected.Add((& $RefuseRevealed $Found.FullName)); continue }
            if (($Found.Name -like 'AllSubscriptions_*.zip') -or ($Found.Name -like 'shard-*.zip')) { continue }
            $Sources.Add([pscustomobject]@{ Kind = 'PerSubZip'; File = $Found.FullName })
        }

        $Bundles = [System.Collections.Generic.List[object]]::new()
        foreach ($Pattern in @('AllSubscriptions_*.zip', 'shard-*.zip'))
        {
            foreach ($Found in Get-ChildItem -LiteralPath $Item.FullName -Recurse -File -Filter $Pattern -ErrorAction SilentlyContinue -ErrorVariable +EnumErrors)
            {
                if ($Found.FullName -like $Excl) { $Rejected.Add((& $RefuseRevealed $Found.FullName)); continue }
                $Bundles.Add($Found)
            }
        }

        if ($Sources.Count -eq $BeforeCount)
        {
            foreach ($Found in $Bundles)
            {
                $Sources.Add([pscustomobject]@{ Kind = 'ConsolidatedZip'; File = $Found.FullName })
            }
        }
        elseif ($Bundles.Count -gt 0)
        {
            foreach ($Found in $Bundles)
            {
                $Skipped.Add(('{0} (skipped: extracted reports were found alongside it, so its contents were not opened to avoid double counting)' -f $Found.FullName))
            }
        }

        foreach ($E in @($EnumErrors))
        {
            $Where = $Item.FullName
            if ($E.TargetObject) { $Where = [string]$E.TargetObject }
            $Unreadable.Add(('{0}: {1}' -f $Where, $E.Exception.Message))
        }
    }

    # De-duplication key. A stamped report keys on its stamp so the same report
    # reached two ways (a loose json and the zip beside it) collapses to one unit.
    # A stamp-LESS file keys on its FULL PATH, not its base name, so two distinct
    # stamp-less inventories that happen to share a base name (a/ResourcesReport.zip
    # and b/ResourcesReport.zip) stay DISTINCT instead of collapsing into one group
    # where one would be dropped from Sources with nothing recorded - a silent false
    # confirmed zero. This mirrors the reader-side fallback keys, which are already
    # full-path-unique, so discovery and coverage cannot drift in opposite directions.
    $Grouped = @($Sources | Group-Object {
            $Stamp = [regex]::Match([System.IO.Path]::GetFileName($_.File), $Script:RdaReportStampPattern)
            if ($Stamp.Success) { $Stamp.Groups[1].Value } else { $_.File }
        })
    $Deduped = [System.Collections.Generic.List[object]]::new()
    foreach ($G in $Grouped)
    {
        $Best = @($G.Group | Sort-Object { Get-RdaSourceKindRank -Kind $_.Kind }, { $_.File })[0]
        $Deduped.Add($Best)
    }

    return [pscustomobject]@{
        Sources    = @($Deduped)
        Missing    = @($Missing | Sort-Object -Unique)
        Unreadable = @($Unreadable | Sort-Object -Unique)
        Rejected   = @($Rejected | Sort-Object -Unique)
        Skipped    = @($Skipped | Sort-Object -Unique)
    }
}

function New-RdaFindResult
{
    <#
    .SYNOPSIS
        Build the Find-RdaResource result object.
    .DESCRIPTION
        One constructor for every return path, so the shape cannot drift between
        the early-exit and the completed-scan cases. Write-RdaFindSummary reads
        these fields and every one of them is always present.

        [CmdletBinding()] is load-bearing here, not decoration: in a simple
        function an unrecognised -Foo is silently taken as a POSITIONAL argument,
        so a single mistyped parameter name would produce exactly the malformed
        result object this constructor exists to make impossible.
    #>
    [CmdletBinding()]
    param(
        $Rows = @(),
        [int]$SourceCount = 0,
        [int]$UnitsRead = 0,
        [int]$UnitReadAttempts = 0,
        [int]$ReadCount = 0,
        $Failures = @(),
        $Missing = @(),
        $Unreadable = @(),
        $Rejected = @(),
        $Skipped = @(),
        $DuplicateUnits = @(),
        $TypePresence = @{},
        [string[]]$ResourceType = @(),
        [string[]]$SumBy = @(),
        [string]$GroupBy = '',
        [double]$ElapsedSeconds = 0
    )

    return [pscustomobject]@{
        Rows             = @($Rows)
        SourceCount      = $SourceCount
        UnitsRead        = $UnitsRead
        UnitReadAttempts = $UnitReadAttempts
        ReadCount        = $ReadCount
        Failures         = @($Failures)
        Missing          = @($Missing)
        Unreadable       = @($Unreadable)
        Rejected         = @($Rejected)
        Skipped          = @($Skipped)
        DuplicateUnits   = @($DuplicateUnits)
        TypePresence     = $TypePresence
        ResourceType     = $ResourceType
        SumBy            = $SumBy
        GroupBy          = $GroupBy
        ElapsedSeconds   = $ElapsedSeconds
    }
}

function Find-RdaResource
{
    <#
    .SYNOPSIS
        Find every row of the given resource type(s) across many report bundles.
    .DESCRIPTION
        Returns a result object whose Rows property holds one entry per matching
        resource. Reads only Inventory_*.json out of each bundle, makes no Azure
        calls, and writes nothing back into the scanned tree.
    .PARAMETER Path
        One or more scan roots, per-subscription zips, consolidated bundles, or
        Inventory_*.json files. Directories are searched recursively.
    .PARAMETER ResourceType
        Collector name(s) whose rows to return, matching the Inventory_*.json keys
        (which are the Services/*.ps1 base names). De-duplicated here rather than
        trusted from the caller, because a repeated or case-variant name would
        otherwise be counted twice per inventory when measuring coverage.
    .PARAMETER SumBy
        Numeric field(s) to total across the matches, e.g. ClusterSize for AVS
        host counts. This is the "how big is it" figure.
    .PARAMETER GroupBy
        Field to break the match count down by, e.g. SKU or Location.
    .PARAMETER ThrottleLimit
        Parallel readers. The work is I/O bound on many small zip reads.

        Memory ceiling: reading a per-sub report nested INSIDE a consolidated
        bundle requires buffering that inner zip, because ZipArchive in read mode
        needs a seekable stream and an inner entry stream is not seekable. The
        high-water mark is therefore roughly ThrottleLimit multiplied by the
        largest inner zip. Lower this when scanning consolidated bundles whose
        per-sub zips carry large Consumption_*.csv members. Reads of per-sub zips
        already on disk do not buffer and are unaffected.
    .PARAMETER HeartbeatLogFile
        Optional durable progress log, forwarded to Write-RdaProgress.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Path,
        [Parameter(Mandatory = $true)][string[]]$ResourceType,
        [string[]]$SumBy,
        [string]$GroupBy,
        [int]$ThrottleLimit = 12,
        [string]$HeartbeatLogFile
    )

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Assert-RdaRevealedExclusion -Pattern $Script:RdaRevealedExclusion
    $RevealedExclusion = $Script:RdaRevealedExclusion
    $StampPattern = $Script:RdaReportStampPattern

    $Wanted = @($ResourceType | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($Wanted.Count -eq 0)
    {
        throw 'No usable -ResourceType was supplied.'
    }

    Write-Host ''
    Write-Host ('Searching for [{0}] across: {1}' -f ($Wanted -join ', '), ($Path -join '; ')) -ForegroundColor Cyan

    $Discovered = Get-RdaInventorySource -Path $Path

    foreach ($M in @($Discovered.Missing))
    {
        Write-Host ('  WARNING: path not found, skipped: {0}' -f $M) -ForegroundColor Yellow
    }
    foreach ($R in @($Discovered.Rejected))
    {
        Write-Host ('  WARNING: refused: {0}' -f $R) -ForegroundColor Yellow
    }
    foreach ($U in @($Discovered.Unreadable))
    {
        Write-Host ('  WARNING: could not enumerate: {0}' -f $U) -ForegroundColor Yellow
    }
    foreach ($S in @($Discovered.Skipped))
    {
        Write-Host ('  WARNING: bundle not opened: {0}' -f $S) -ForegroundColor Yellow
    }

    $Sources = @($Discovered.Sources)

    if ($Sources.Count -eq 0)
    {
        # Distinguish "nothing was there" from "candidates were found but every one
        # was excluded". Saying "check the path" when the path was correct and the
        # bundles were deliberately refused (e.g. every report was a de-obfuscated
        # *_revealed copy the PII guard rejected) sends the operator to fix a
        # non-problem. The specific per-entry warnings were already printed above.
        $Excluded = (@($Discovered.Rejected).Count + @($Discovered.Unreadable).Count + @($Discovered.Skipped).Count)
        if ($Excluded -gt 0)
        {
            Write-Host 'No usable report bundles remained: candidates were found but every one was' -ForegroundColor Red
            Write-Host 'refused, unreadable, or skipped (see the warnings above for each). This is NOT' -ForegroundColor Red
            Write-Host 'a statement that the path is wrong.' -ForegroundColor Red
        }
        else
        {
            Write-Host 'No report bundles or inventory files found under the given path(s).' -ForegroundColor Red
            Write-Host 'Expected one of: Inventory_*.json, ResourcesReport*.zip, AllSubscriptions_*.zip / shard-*.zip' -ForegroundColor Yellow
        }
        return New-RdaFindResult -SourceCount 0 -Missing $Discovered.Missing -Unreadable $Discovered.Unreadable `
            -Rejected $Discovered.Rejected -Skipped $Discovered.Skipped -ResourceType $Wanted `
            -SumBy $SumBy -GroupBy $GroupBy `
            -ElapsedSeconds ([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2))
    }

    Write-Host ('  {0} source(s) to read ({1})' -f
        $Sources.Count,
        (($Sources | Group-Object Kind | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ', ')) -ForegroundColor Gray

    $Total = $Sources.Count
    $Done = 0
    $Activity = 'Reading subscription inventories'
    $EmitProgress = [bool](Get-Command -Name Write-RdaProgress -ErrorAction SilentlyContinue)

    $Results = $Sources | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $Source = $_
        $Types = $using:Wanted
        $Excl = $using:RevealedExclusion
        $Stamp = $using:StampPattern

        # Read-Inventory is defined INSIDE the -Parallel scriptblock on purpose: a
        # runspace cannot see enclosing-scope functions, so it must be re-parsed
        # once per source. That per-iteration re-definition cost is accepted and is
        # immaterial beside the zip I/O each iteration does. Do NOT try to hoist it
        # out and relay it via $using: - a scriptblock captured that way still
        # cannot resolve against this runspace, which is the same cross-runspace
        # trap the $using: pattern for the stamp/exclusion literals works around.
        function Read-Inventory
        {
            [CmdletBinding()]
            param([string]$Json, [string]$SourceFile, [string]$ReportId, [string[]]$Types)

            $Obj = $Json | ConvertFrom-Json

            if (($null -eq $Obj) -or
                ($Obj -isnot [System.Management.Automation.PSCustomObject]) -or
                (@($Obj.PSObject.Properties.Name).Count -eq 0))
            {
                throw ('inventory is empty or not a JSON object: {0}' -f $SourceFile)
            }

            $Rows = [System.Collections.Generic.List[object]]::new()
            $Present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            foreach ($T in $Types)
            {
                $Prop = $Obj.PSObject.Properties[$T]

                if (-not $Prop) { continue }

                # Stamp the inventory's ACTUAL key name, not the operator's -ResourceType
                # casing. The lookup above is case-insensitive, so 'vmware' matches the
                # 'VMWare' key; echoing the operator's input into RdaResourceType (and the
                # coverage set) would let two runs of one estate emit 'vmware' and 'VMWare'
                # and split under a case-sensitive downstream Group-Object. The inventory
                # key is canonical-by-production (ResourceInventory.ps1 derives it from the
                # Services/*.ps1 base name), so keying on it removes that variance.
                $Canonical = $Prop.Name
                [void]$Present.Add($Canonical)

                foreach ($Row in @($Prop.Value | Where-Object { $null -ne $_ }))
                {
                    $New = [ordered]@{}
                    foreach ($RP in $Row.PSObject.Properties) { $New[$RP.Name] = $RP.Value }
                    $New['RdaResourceType'] = $Canonical
                    $New['RdaReportId'] = $ReportId
                    $New['RdaSourceFile'] = $SourceFile
                    $Rows.Add([pscustomobject]$New)
                }
            }
            return [pscustomobject]@{ Rows = $Rows; TypesPresent = @($Present) }
        }

        $Match = [regex]::Match([System.IO.Path]::GetFileName($Source.File), $Stamp)
        if ($Match.Success) { $ReportId = $Match.Groups[1].Value }
        else { $ReportId = $Source.File }

        try
        {
            switch ($Source.Kind)
            {
                'LooseJson'
                {
                    $Json = [System.IO.File]::ReadAllText($Source.File)
                    $Read = Read-Inventory -Json $Json -SourceFile $Source.File -ReportId $ReportId -Types $Types
                    [pscustomobject]@{
                        ReportId = $ReportId; Rows = $Read.Rows; Failure = $null; InnerFailures = @()
                        Units = @([pscustomobject]@{ UnitId = $ReportId; TypesPresent = $Read.TypesPresent })
                    }
                }

                'PerSubZip'
                {
                    $Zip = [System.IO.Compression.ZipFile]::OpenRead($Source.File)
                    try
                    {
                        $Entry = @($Zip.Entries | Where-Object { $_.Name -like 'Inventory_*.json' })[0]
                        if (-not $Entry)
                        {
                            [pscustomobject]@{
                                ReportId = $ReportId; Rows = @(); Failure = ('no Inventory_*.json inside {0}' -f $Source.File)
                                InnerFailures = @(); Units = @()
                            }
                        }
                        else
                        {
                            $Stream = $Entry.Open()
                            $Reader = [System.IO.StreamReader]::new($Stream)
                            try { $Json = $Reader.ReadToEnd() }
                            finally { $Reader.Dispose(); $Stream.Dispose() }
                            $Read = Read-Inventory -Json $Json -SourceFile $Source.File -ReportId $ReportId -Types $Types
                            [pscustomobject]@{
                                ReportId = $ReportId; Rows = $Read.Rows; Failure = $null; InnerFailures = @()
                                Units = @([pscustomobject]@{ UnitId = $ReportId; TypesPresent = $Read.TypesPresent })
                            }
                        }
                    }
                    finally { $Zip.Dispose() }
                }

                'ConsolidatedZip'
                {
                    $Collected = [System.Collections.Generic.List[object]]::new()
                    $InnerFailures = [System.Collections.Generic.List[string]]::new()
                    $Units = [System.Collections.Generic.List[object]]::new()

                    $Outer = [System.IO.Compression.ZipFile]::OpenRead($Source.File)
                    try
                    {
                        $Candidates = @($Outer.Entries | Where-Object { $_.Name -like 'ResourcesReport*.zip' })

                        $InnerEntries = [System.Collections.Generic.List[object]]::new()
                        foreach ($C in $Candidates)
                        {
                            if ($C.FullName -like $Excl)
                            {
                                $InnerFailures.Add(('{0}!{1} (de-obfuscated report, refused by the PII guard: it carries real identifiers)' -f $Source.File, $C.FullName))
                                continue
                            }
                            $InnerEntries.Add($C)
                        }

                        if ($Candidates.Count -eq 0)
                        {
                            $InnerFailures.Add(('no per-subscription ResourcesReport*.zip inside {0}' -f $Source.File))
                        }

                        foreach ($Inner in $InnerEntries)
                        {
                            try
                            {
                                $Memory = [System.IO.MemoryStream]::new()
                                try
                                {
                                    $InnerStream = $Inner.Open()
                                    try { $InnerStream.CopyTo($Memory) }
                                    finally { $InnerStream.Dispose() }
                                    $Memory.Position = 0
                                    $InnerZip = [System.IO.Compression.ZipArchive]::new($Memory, [System.IO.Compression.ZipArchiveMode]::Read)
                                    try
                                    {
                                        $Entry = @($InnerZip.Entries | Where-Object { $_.Name -like 'Inventory_*.json' })[0]
                                        if (-not $Entry)
                                        {
                                            $InnerFailures.Add(('no Inventory_*.json inside {0}!{1}' -f $Source.File, $Inner.Name))
                                        }
                                        else
                                        {
                                            $Stream = $Entry.Open()
                                            $Reader = [System.IO.StreamReader]::new($Stream)
                                            try { $Json = $Reader.ReadToEnd() }
                                            finally { $Reader.Dispose(); $Stream.Dispose() }

                                            $IM = [regex]::Match($Inner.Name, $Stamp)
                                            if ($IM.Success) { $InnerId = $IM.Groups[1].Value }
                                            else { $InnerId = '{0}!{1}' -f $Source.File, $Inner.FullName }

                                            $Read = Read-Inventory -Json $Json -SourceFile ('{0}!{1}' -f $Source.File, $Inner.Name) -ReportId $InnerId -Types $Types
                                            foreach ($Row in $Read.Rows) { $Collected.Add($Row) }
                                            $Units.Add([pscustomobject]@{ UnitId = $InnerId; TypesPresent = $Read.TypesPresent })
                                        }
                                    }
                                    finally { $InnerZip.Dispose() }
                                }
                                finally { $Memory.Dispose() }
                            }
                            catch
                            {
                                $InnerFailures.Add(('{0}!{1}: {2}' -f $Source.File, $Inner.Name, $_.Exception.Message))
                            }
                        }
                    }
                    finally { $Outer.Dispose() }

                    [pscustomobject]@{
                        ReportId = $ReportId; Rows = $Collected; Failure = $null
                        InnerFailures = @($InnerFailures); Units = @($Units)
                    }
                }

                default
                {
                    [pscustomobject]@{
                        ReportId = $ReportId; Rows = @()
                        Failure = ('unrecognised source kind {0} for {1}' -f $Source.Kind, $Source.File)
                        InnerFailures = @(); Units = @()
                    }
                }
            }
        }
        catch
        {
            [pscustomobject]@{
                ReportId = $ReportId; Rows = @(); Failure = ('{0}: {1}' -f $Source.File, $_.Exception.Message)
                InnerFailures = @(); Units = @()
            }
        }
    } | ForEach-Object {
        $Done++
        if ($EmitProgress -and (($Done % 50 -eq 0) -or ($Done -eq $Total)))
        {
            $ProgressArgs = @{
                Activity    = $Activity
                CurrentItem = $_.ReportId
                Index       = $Done
                Total       = $Total
            }
            if ($HeartbeatLogFile) { $ProgressArgs.HeartbeatLogFile = $HeartbeatLogFile }
            Write-RdaProgress @ProgressArgs
        }
        $_
    }

    if ($EmitProgress) { Write-RdaProgress -Activity $Activity -Completed }

    $Results = @($Results)
    $Failures = @(
        @($Results | Where-Object { $_.Failure } | ForEach-Object { $_.Failure })
        @($Results | ForEach-Object { $_.InnerFailures } | Where-Object { $_ })
    )
    $Rows = @($Results | ForEach-Object { $_.Rows } | Where-Object { $null -ne $_ })

    $UnitIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $TypeUnitIds = @{}
    foreach ($T in $Wanted)
    {
        $TypeUnitIds[$T] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    $Attempts = 0
    foreach ($Res in $Results)
    {
        foreach ($Unit in @($Res.Units))
        {
            $Attempts++
            [void]$UnitIds.Add($Unit.UnitId)
            foreach ($T in @($Unit.TypesPresent))
            {
                if ($TypeUnitIds.ContainsKey($T)) { [void]$TypeUnitIds[$T].Add($Unit.UnitId) }
            }
        }
    }

    $TypePresence = @{}
    foreach ($T in $Wanted) { $TypePresence[$T] = $TypeUnitIds[$T].Count }

    $DuplicateUnits = @()
    if ($Attempts -gt $UnitIds.Count)
    {
        $Named = [System.Collections.Generic.List[string]]::new()
        $RowsByReportId = @($Rows | Group-Object RdaReportId)
        foreach ($G in $RowsByReportId)
        {
            $SourceCountForId = @($G.Group | Group-Object RdaSourceFile).Count
            if ($SourceCountForId -gt 1)
            {
                $Named.Add(('{0} (read from {1} different sources)' -f $G.Name, $SourceCountForId))
            }
        }
        $DuplicateUnits = @($Named)
        Write-Host ('  WARNING: {0} inventory read(s) were duplicates ({1} attempts, {2} distinct subscriptions).' -f
            ($Attempts - $UnitIds.Count), $Attempts, $UnitIds.Count) -ForegroundColor Yellow
        if ($Rows.Count -gt 0)
        {
            Write-Host '  Matched-row counts and any -SumBy total may therefore be INFLATED.' -ForegroundColor Yellow
        }
        else
        {
            Write-Host '  No rows matched, so nothing was INFLATED; the duplicate source is still worth removing.' -ForegroundColor Yellow
        }
    }

    return New-RdaFindResult -Rows $Rows -SourceCount $Sources.Count `
        -UnitsRead $UnitIds.Count -UnitReadAttempts $Attempts `
        -ReadCount @($Results | Where-Object { -not $_.Failure }).Count `
        -Failures $Failures -Missing $Discovered.Missing -Unreadable $Discovered.Unreadable `
        -Rejected $Discovered.Rejected -Skipped $Discovered.Skipped -DuplicateUnits $DuplicateUnits `
        -TypePresence $TypePresence -ResourceType $Wanted -SumBy $SumBy -GroupBy $GroupBy `
        -ElapsedSeconds ([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2))
}

function Get-RdaRowField
{
    <#
    .SYNOPSIS
        Union of field names across matched rows, for a fail-loud error message.
    .DESCRIPTION
        Deliberately case-SENSITIVE, unlike every other set in this file. Two
        differently-cased field names are two distinct schema keys and the
        operator should see both in the "Available:" list, rather than having one
        of them silently hidden.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory = $true)]$Rows)

    $Names = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($R in @($Rows))
    {
        foreach ($P in $R.PSObject.Properties) { [void]$Names.Add($P.Name) }
    }
    return @($Names | Sort-Object)
}

function Get-RdaTypeCoverage
{
    <#
    .SYNOPSIS
        Classify, per requested type, how much of the scan could speak to it.
    .DESCRIPTION
        Three states, judged against the number of DISTINCT inventories read:

          None     the key was in NO inventory, so absence cannot be claimed
          Partial  some inventories carried the key and some did not
          Full     every inventory read carried the key

        Fails CLOSED. Anything unexpected - no usable TypePresence, nothing read,
        or a count somehow exceeding the denominator - classifies as None, so an
        unforeseen shape degrades toward "cannot confirm" rather than toward a
        confident zero. Tested as IDictionary rather than Hashtable so an ordered
        dictionary is accepted, while a PSCustomObject (what a JSON round-trip
        would produce) is correctly refused.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Result)

    $Coverage = @{}
    $Types = @($Result.ResourceType)
    $UnitsRead = [int]$Result.UnitsRead
    $Presence = $Result.TypePresence

    foreach ($T in $Types)
    {
        if (($Presence -isnot [System.Collections.IDictionary]) -or ($UnitsRead -le 0))
        {
            $Coverage[$T] = 'None'
            continue
        }

        $Count = 0
        if ($Presence.Contains($T)) { $Count = [int]$Presence[$T] }

        if ($Count -le 0) { $Coverage[$T] = 'None' }
        elseif ($Count -lt $UnitsRead) { $Coverage[$T] = 'Partial' }
        elseif ($Count -eq $UnitsRead) { $Coverage[$T] = 'Full' }
        else { $Coverage[$T] = 'None' }
    }
    return $Coverage
}

function Write-RdaFindSummary
{
    <#
    .SYNOPSIS
        Render the operator-facing summary for a Find-RdaResource result.
    .DESCRIPTION
        Reports the scope that was actually scanned and states a zero as an
        explicit zero. It only calls a zero CONFIRMED when all of the following
        hold: at least one inventory was read, every inventory read carried the
        requested key, and nothing was missing, refused, unreadable, skipped or
        failed. Otherwise it names precisely what it could not establish, rather
        than asserting an absence it has not earned.

        Reads the requested types from the result itself, so the summary cannot
        describe a type that was never scanned.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Result)

    $Rows = @($Result.Rows)
    $Types = @($Result.ResourceType)
    $Label = $Types -join ', '
    $UnitsRead = [int]$Result.UnitsRead

    $FieldUnion = $null

    Write-Host ''
    Write-Host '================ RESULT ================' -ForegroundColor Cyan
    Write-Host ('  Resource type(s)          : {0}' -f $Label)
    Write-Host ('  Sources read              : {0} of {1}' -f $Result.ReadCount, $Result.SourceCount)
    Write-Host ('  Subscription inventories  : {0}' -f $UnitsRead)

    $Coverage = Get-RdaTypeCoverage -Result $Result
    $TypesNone = @($Types | Where-Object { $Coverage[$_] -eq 'None' })
    $TypesPartial = @($Types | Where-Object { $Coverage[$_] -eq 'Partial' })

    # DuplicateUnits is deliberately NOT part of Incomplete. A subscription read
    # twice inflates counts and sums but can never cause a FALSE absence: the
    # coverage arithmetic is set-based (UnitIds/TypeUnitIds are HashSets keyed on
    # UnitId), so a repeated read collapses to the same id and cannot push a
    # partial coverage up to Full. Folding DuplicateUnits into Incomplete would
    # weaken the confirmed-zero test into "never confirmable when anything was
    # read twice", which is strictly worse. Duplicate reads are surfaced on their
    # own line below instead.
    $Incomplete = (
        (@($Result.Missing).Count -gt 0) -or
        (@($Result.Unreadable).Count -gt 0) -or
        (@($Result.Rejected).Count -gt 0) -or
        (@($Result.Skipped).Count -gt 0) -or
        (@($Result.Failures).Count -gt 0)
    )

    if ($Rows.Count -eq 0)
    {
        Write-Host '  Matching resources        : 0' -ForegroundColor Yellow
        Write-Host ''

        if ([int]$Result.SourceCount -eq 0)
        {
            $Excluded = (@($Result.Rejected).Count + @($Result.Unreadable).Count + @($Result.Skipped).Count + @($Result.Missing).Count)
            if ($Excluded -gt 0)
            {
                Write-Host '  NOTHING WAS SCANNED. Candidates were found but every one was refused,' -ForegroundColor Red
                Write-Host '  unreadable, skipped, or missing (see the counts and warnings above), so no' -ForegroundColor Red
                Write-Host '  inventory could be read. This does NOT mean the path is wrong.' -ForegroundColor Red
            }
            else
            {
                Write-Host '  NOTHING WAS SCANNED. No report bundles were found under the given path(s),' -ForegroundColor Red
                Write-Host '  so this result says nothing about whether the type exists. Check the path.' -ForegroundColor Red
            }
        }
        elseif ($UnitsRead -eq 0)
        {
            Write-Host ('  NO INVENTORY WAS READ. {0} source(s) were found but none produced a' -f $Result.SourceCount) -ForegroundColor Red
            Write-Host '  readable inventory, so this result cannot speak to the type at all.' -ForegroundColor Red
            Write-Host '  See the READ FAILURES below for why each source could not be read.' -ForegroundColor Red
        }
        elseif ($TypesNone.Count -gt 0)
        {
            Write-Host ('  CANNOT CONFIRM ABSENCE. The key(s) [{0}] were present in NO inventory read.' -f ($TypesNone -join ', ')) -ForegroundColor Red
            Write-Host '  These bundles cannot speak to that type at all, which is NOT the same as' -ForegroundColor Red
            Write-Host '  the type being absent from the estate. Likely causes: the bundles predate' -ForegroundColor Red
            Write-Host '  the collector, or the run was scoped with -Service.' -ForegroundColor Red
        }
        elseif ($TypesPartial.Count -gt 0)
        {
            Write-Host '  PARTIAL COVERAGE - this is NOT a confirmed zero.' -ForegroundColor Red
            foreach ($T in $TypesPartial)
            {
                $Have = [int]$Result.TypePresence[$T]
                Write-Host ('    {0}: only {1} of {2} inventories carried this key; the other {3} could' -f
                    $T, $Have, $UnitsRead, ($UnitsRead - $Have)) -ForegroundColor Red
                Write-Host '      not speak to the type, so absence is unproven for those subscriptions.' -ForegroundColor Red
            }
        }
        elseif ($Incomplete)
        {
            Write-Host ('  PARTIAL SCAN. Read {0} inventory/inventories and found no [{1}], but the' -f $UnitsRead, $Label) -ForegroundColor Yellow
            Write-Host '  scan did not cover everything requested, so this is NOT a confirmed zero.' -ForegroundColor Yellow
        }
        else
        {
            Write-Host ('  Scanned {0} subscription inventory/inventories, every one of which carried' -f $UnitsRead) -ForegroundColor Yellow
            Write-Host ('  the [{0}] key, and found NO such resources.' -f $Label) -ForegroundColor Yellow
            Write-Host '  This is a confirmed zero for the scope above, not a failed scan.' -ForegroundColor Yellow
        }
    }
    else
    {
        # Group by the row's Subscription field - that is the identity that best
        # answers "which subscription has this resource", which is this tool's
        # whole stated purpose. A row with no (or empty) Subscription field falls
        # back to its RdaReportId (the per-subscription report stamp) so nothing
        # is silently dropped from the list. The printed count and the printed
        # list MUST stay consistent, so the count line is the number of distinct
        # groups produced here - NOT the old raw Group-Object RdaReportId count,
        # which could differ when a report's rows carry a different Subscription
        # value or when several reports share one subscription.
        $Groups = $Rows | Group-Object -Property {
            $Sub = $_.Subscription
            if (($null -ne $Sub) -and ("$Sub".Trim() -ne '')) { "sub`0$Sub" }
            else { "stamp`0{0}" -f $_.RdaReportId }
        }
        $Groups = @($Groups)

        Write-Host ('  Matching resources        : {0}' -f $Rows.Count) -ForegroundColor Green
        Write-Host ('  Subscriptions containing  : {0}' -f $Groups.Count) -ForegroundColor Green

        # List each containing subscription with its per-subscription match
        # count, so the operator can see WHICH subscription holds the resource
        # rather than only how many do. Bounded so a very large estate does not
        # flood the console - the full list is always in -CsvPath output.
        $ListCap = 50
        $Shown = 0
        $LooksObfuscated = $false
        foreach ($G in ($Groups | Sort-Object -Property Count -Descending))
        {
            if ($Shown -ge $ListCap) { break }

            # The grouping key is "<kind>`0<value>"; split it back into the kind
            # and the human-facing identity.
            $Parts = $G.Name -split "`0", 2
            $Kind = $Parts[0]
            $Identity = $Parts[1]

            $Suffix = ''
            if ($Kind -eq 'stamp')
            {
                # No Subscription field on these rows: make it clear the value is
                # a report stamp, not a subscription name.
                $Suffix = ' (report stamp)'
            }
            elseif ($Identity -match '^(prod|nonprod)_')
            {
                # An obfuscated report (-Obfuscate) tokenises the subscription.
                # We do NOT de-obfuscate here (that is Reveal.ps1's job) - just
                # note once that some values may be masked.
                $LooksObfuscated = $true
            }

            $MatchWord = if ($G.Count -eq 1) { 'match' } else { 'matches' }
            Write-Host ('    - {0,-40}{1} ({2} {3})' -f $Identity, $Suffix, $G.Count, $MatchWord) -ForegroundColor Green
            $Shown++
        }

        if ($Groups.Count -gt $ListCap)
        {
            Write-Host ('    ... and {0} more (see -CsvPath for the full list)' -f ($Groups.Count - $ListCap)) -ForegroundColor Green
        }

        if ($LooksObfuscated)
        {
            Write-Host '    (some subscription values look obfuscated; use Reveal.ps1 to un-mask)' -ForegroundColor DarkGray
        }

        foreach ($Field in @($Result.SumBy))
        {
            if (-not $Field) { continue }
            $Present = @($Rows | Where-Object { $_.PSObject.Properties[$Field] })
            if ($Present.Count -eq 0)
            {
                if ($null -eq $FieldUnion) { $FieldUnion = Get-RdaRowField -Rows $Rows }
                Write-Host ('  Sum of {0,-18}: field not present on any matched row. Available: {1}' -f
                    $Field, ($FieldUnion -join ', ')) -ForegroundColor Yellow
                continue
            }

            $Numeric = [System.Collections.Generic.List[double]]::new()
            $Blank = 0
            $NonNumeric = 0
            foreach ($Row in $Present)
            {
                $Value = $Row.$Field
                if (($null -eq $Value) -or ("$Value" -eq '')) { $Blank++; continue }
                $Parsed = 0.0
                $Ok = [double]::TryParse(
                    "$Value",
                    [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [ref]$Parsed)
                if ($Ok) { $Numeric.Add($Parsed) } else { $NonNumeric++ }
            }

            if ($Numeric.Count -gt 0)
            {
                $Sum = ($Numeric | Measure-Object -Sum).Sum
                Write-Host ('  Sum of {0,-18}: {1}' -f $Field, $Sum) -ForegroundColor Green
                if ($Blank -gt 0)
                {
                    Write-Host ('      note: {0} of {1} row(s) had no {2} value and contributed 0' -f $Blank, $Present.Count, $Field) -ForegroundColor Yellow
                }
            }
            elseif ($NonNumeric -gt 0)
            {
                Write-Host ('  Sum of {0,-18}: NOT NUMERIC - no matched row carried a parseable number' -f $Field) -ForegroundColor Red
            }
            else
            {
                Write-Host ('  Sum of {0,-18}: NO VALUES - every matched row had an empty {0}' -f $Field) -ForegroundColor Red
            }

            if ($NonNumeric -gt 0)
            {
                Write-Host ('      note: {0} of {1} row(s) had a non-numeric {2} and were EXCLUDED' -f $NonNumeric, $Present.Count, $Field) -ForegroundColor Yellow
            }
        }

        if ($Result.GroupBy)
        {
            $Field = $Result.GroupBy
            Write-Host ''
            Write-Host ('  Breakdown by {0}:' -f $Field) -ForegroundColor Cyan
            $Any = @($Rows | Where-Object { $_.PSObject.Properties[$Field] })
            if ($Any.Count -eq 0)
            {
                if ($null -eq $FieldUnion) { $FieldUnion = Get-RdaRowField -Rows $Rows }
                Write-Host ('    field not present on any matched row. Available: {0}' -f
                    ($FieldUnion -join ', ')) -ForegroundColor Yellow
            }
            else
            {
                $Grouped = $Any | Group-Object -Property @{
                    Expression = {
                        if ([string]::IsNullOrWhiteSpace([string]$_.$Field)) { '(blank)' } else { [string]$_.$Field }
                    }
                }
                foreach ($G in ($Grouped | Sort-Object Count -Descending))
                {
                    Write-Host ('    {0,-28} {1}' -f $G.Name, $G.Count)
                }
                $NoField = $Rows.Count - $Any.Count
                if ($NoField -gt 0)
                {
                    Write-Host ('    {0,-28} {1}' -f '(field not present)', $NoField) -ForegroundColor Yellow
                }
            }
        }

        if ($TypesNone.Count -gt 0)
        {
            Write-Host ''
            foreach ($T in $TypesNone)
            {
                Write-Host ('  NOTE: the [{0}] key was present in NO inventory read, so nothing above speaks to' -f $T) -ForegroundColor Red
                Write-Host ('  {0} at all - its absence is unproven, not confirmed.' -f $T) -ForegroundColor Red
            }
        }
        if ($TypesPartial.Count -gt 0)
        {
            Write-Host ''
            foreach ($T in $TypesPartial)
            {
                $Have = [int]$Result.TypePresence[$T]
                Write-Host ('  NOTE: only {0} of {1} inventories carried the [{2}] key, so the counts' -f $Have, $UnitsRead, $T) -ForegroundColor Yellow
                Write-Host '  above are a LOWER BOUND for the estate, not a complete total.' -ForegroundColor Yellow
            }
        }
        elseif ($Incomplete)
        {
            Write-Host ''
            Write-Host '  NOTE: the scan was PARTIAL (see warnings/failures), so the counts above' -ForegroundColor Yellow
            Write-Host '  are a lower bound, not a complete total.' -ForegroundColor Yellow
        }
    }

    if (@($Result.Missing).Count -gt 0)
    {
        Write-Host ('  Paths not found           : {0}' -f @($Result.Missing).Count) -ForegroundColor Yellow
    }
    if (@($Result.Rejected).Count -gt 0)
    {
        Write-Host ('  Paths refused             : {0}' -f @($Result.Rejected).Count) -ForegroundColor Yellow
    }
    if (@($Result.Unreadable).Count -gt 0)
    {
        Write-Host ('  Subtrees not enumerable   : {0}' -f @($Result.Unreadable).Count) -ForegroundColor Yellow
    }
    if (@($Result.Skipped).Count -gt 0)
    {
        Write-Host ('  Bundles not opened        : {0}' -f @($Result.Skipped).Count) -ForegroundColor Yellow
    }
    $Attempts = [int]$Result.UnitReadAttempts
    if ($Attempts -gt $UnitsRead)
    {
        # A repeated read can add a row or a covered subscription but never remove
        # one, so with zero matched rows nothing was inflated and the confirmed-zero
        # verdict above stands; the exit code makes the same distinction.
        if ($Rows.Count -gt 0)
        {
            Write-Host ('  Subscriptions read twice  : {0} duplicate read(s) of {1} attempts (row counts and any sum may be INFLATED)' -f
                ($Attempts - $UnitsRead), $Attempts) -ForegroundColor Red
        }
        else
        {
            Write-Host ('  Subscriptions read twice  : {0} duplicate read(s) of {1} attempts (no rows matched, so nothing was INFLATED)' -f
                ($Attempts - $UnitsRead), $Attempts) -ForegroundColor Yellow
        }
        foreach ($D in (@($Result.DuplicateUnits) | Select-Object -First 5))
        {
            Write-Host ('    {0}' -f $D) -ForegroundColor Red
        }
    }

    if (@($Result.Failures).Count -gt 0)
    {
        Write-Host ''
        Write-Host ('  READ FAILURES: {0}' -f @($Result.Failures).Count) -ForegroundColor Red
        foreach ($F in (@($Result.Failures) | Select-Object -First 10))
        {
            Write-Host ('    {0}' -f $F) -ForegroundColor Red
        }
        if (@($Result.Failures).Count -gt 10)
        {
            Write-Host ('    ... and {0} more (display limit only; the full list is on the returned' -f
                (@($Result.Failures).Count - 10)) -ForegroundColor Red
            Write-Host "    object's Failures property, and in -HeartbeatLogFile when supplied)" -ForegroundColor Red
        }
        Write-Host '  Some inventories failed to read, so the figures above cover only those that' -ForegroundColor Yellow
        Write-Host '  READ successfully. "Sources read" counts archives opened, and a consolidated' -ForegroundColor Yellow
        Write-Host '  bundle counts as read even when some reports inside it failed.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host ('  Elapsed: {0}s' -f $Result.ElapsedSeconds) -ForegroundColor Gray
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''
}

