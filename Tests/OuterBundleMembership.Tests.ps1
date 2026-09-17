# Outer Bundle Membership Tests
#
# Pins the member set of the ONE artifact an operator sends: the consolidated
# AllSubscriptions_ResourcesReport_<timestamp>.zip built by Run-AllSubscriptions.ps1.
#
# WHY THIS EXISTS
#
# Every other suite inspects an INNER per-subscription ResourcesReport_*.zip
# (Tests/OutputCompleteness.Tests.ps1 binds $env:TEST_ZIP_PATH to one), and
# Tests/ParallelStreamsAggregation.Tests.ps1 compares two outer bundles against
# each other without pinning either one's membership. So nothing asserted what the
# outer bundle may and may not contain.
#
# That gap matters because complete InventoryReports folders have arrived from the
# field repeatedly. The packaging code builds every archive from an explicit path
# list and cannot produce a folder-zip, but "cannot today" is not a regression
# guard: a future change to the stage 1/2/3 fold could sweep the inventory root.
# The must-NOT-contain block below is that guard, and the obfuscation dictionary is
# the one that actually matters - it is the de-obfuscation key, so shipping it
# silently undoes -Obfuscate for the entire bundle.
#
# INPUT (env var)
#   $env:TEST_ALLSUB_BUNDLE - path to an AllSubscriptions_*.zip from a completed
#                             wrapper run. Not set: every test is skipped, so this
#                             file is inert in suites that have no outer bundle.
#
# Deliberately NO auto-discovery from the default InventoryReports directory: that
# folder accumulates bundles from many runs with different flag combinations, and
# picking an arbitrary one produces false results (the same reasoning
# ParallelStreamsAggregation.Tests.ps1 records for removing its auto-discovery).
#
# Run with: Invoke-Pester ./Tests/OuterBundleMembership.Tests.ps1 -Output Detailed

BeforeDiscovery {
    $script:BundlePath = $env:TEST_ALLSUB_BUNDLE
    $script:HaveBundle = (-not [string]::IsNullOrWhiteSpace($script:BundlePath)) -and (Test-Path -LiteralPath $script:BundlePath)
}

BeforeAll {
    $script:BundlePath = $env:TEST_ALLSUB_BUNDLE

    if (-not [string]::IsNullOrWhiteSpace($script:BundlePath) -and (Test-Path -LiteralPath $script:BundlePath))
    {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $script:BundlePath).Path)
        try
        {
            # FullName keeps the folder prefix (HTML<stamp>/x.html); Name is the leaf.
            $script:EntryPaths = @($Archive.Entries | ForEach-Object { $_.FullName })
            $script:EntryNames = @($Archive.Entries | ForEach-Object { $_.Name })
        }
        finally
        {
            $Archive.Dispose()
        }

        # Root-level members only: no directory separator anywhere in the path.
        $script:RootEntries = @($script:EntryPaths | Where-Object { $_ -notmatch '[\\/]' })
    }
    else
    {
        $script:EntryPaths = @()
        $script:EntryNames = @()
        $script:RootEntries = @()
    }
}

Describe 'Outer bundle membership' -Skip:(-not $script:HaveBundle) {

    Context 'Required members' {

        It 'contains at least one per-subscription ResourcesReport_*.zip at the root' {
            @($script:RootEntries | Where-Object { $_ -like 'ResourcesReport_*.zip' }).Count |
                Should -BeGreaterThan 0 -Because 'the bundle exists to carry the per-subscription data archives'
        }

        It 'contains RunSummary.log at the root' {
            # Stage 2 folds this in and verifies it, because a bundle shipped without
            # a run summary cannot be triaged. A customer has previously received one.
            $script:RootEntries | Should -Contain 'RunSummary.log'
        }

        It 'contains MainSummary.html at the root' {
            $script:RootEntries | Should -Contain 'MainSummary.html'
        }
    }

    Context 'Must NOT contain local-only files (anywhere, at any depth)' {

        # The regression guard. Each of these is deliberately kept on local disk by
        # the packaging code; any of them appearing here means either a packaging
        # regression or that the bundle under test was hand-assembled from the
        # InventoryReports folder rather than produced by the wrapper.

        It 'never contains the obfuscation dictionary' {
            # Highest-severity assertion in this file: the dictionary maps every
            # token back to the real identifier, so shipping it defeats -Obfuscate
            # entirely. No code path adds it to any archive.
            @($script:EntryNames | Where-Object { $_ -like 'ObfuscationDictionary_*' }).Count |
                Should -Be 0 -Because 'the dictionary is the de-obfuscation key and must never leave the tenant'
        }

        It 'never contains a Full_* inventory dump' {
            @($script:EntryNames | Where-Object { $_ -like 'Full_*' }).Count | Should -Be 0
        }

        It 'never contains a PowerShell transcript' {
            # Transcripts capture the signed-in UPN, tenant id and local paths, none
            # of which the obfuscation layer touches.
            @($script:EntryNames | Where-Object { $_ -like 'Transcript_Log_*' -or $_ -like 'RunAllSubscriptions_transcript_*' }).Count |
                Should -Be 0
        }

        It 'never contains a debug or error log' {
            @($script:EntryNames | Where-Object { $_ -like 'DebugLog_*' -or $_ -like 'ErrorLog_*' -or $_ -like 'Heartbeat_*' }).Count |
                Should -Be 0
        }

        It 'never contains resume state or a support-log bundle' {
            @($script:EntryNames | Where-Object { $_ -like '*resume-state*' -or $_ -like 'RdaSupportLogs_*' }).Count |
                Should -Be 0
        }

        It 'never nests another AllSubscriptions_* bundle inside itself' {
            # A folder-zip of InventoryReports would pull in every prior run's bundle.
            @($script:EntryNames | Where-Object { $_ -like 'AllSubscriptions_*' }).Count | Should -Be 0
        }

        It 'never contains any staging directory' {
            # All three staging prefixes the wrapper creates under InventoryRoot.
            # Each is removed in a finally, so any appearing here means a fold ran
            # against a path that was not cleaned up.
            foreach ($Prefix in @('.rda-bundle-', '.rda-runsummary-', '.rda-supportlogs-'))
            {
                @($script:EntryPaths | Where-Object { $_ -like ('*' + $Prefix + '*') }).Count |
                    Should -Be 0 -Because ("{0}* is an internal staging directory" -f $Prefix)
            }
        }
    }

    Context 'Ingestion contract at the outer root' {

        # The per-subscription ingestible members live INSIDE the inner zips. The
        # outer root carries archives plus presentation files, with VMPlacement.csv
        # as the single sanctioned loose data file. A consumer that discovers
        # ingestible files by extension at this level must not find anything else,
        # or the same data gets ingested twice.

        It 'carries no loose Inventory_* or Metrics_* JSON at the root' {
            @($script:RootEntries | Where-Object { $_ -like 'Inventory_*.json' -or $_ -like 'Metrics_*.json' }).Count |
                Should -Be 0 -Because 'those belong inside the per-subscription zips'
        }

        It 'carries no loose Consumption_*.csv at the root' {
            @($script:RootEntries | Where-Object { $_ -like 'Consumption_*.csv' }).Count |
                Should -Be 0 -Because 'consumption data belongs inside the per-subscription zips'
        }

        It 'has VMPlacement.csv as the only loose CSV at the root' {
            $RootCsvs = @($script:RootEntries | Where-Object { $_ -like '*.csv' })
            foreach ($Csv in $RootCsvs)
            {
                $Csv | Should -Be 'VMPlacement.csv' -Because 'it is the one sanctioned loose data file at the outer root'
            }
        }
    }

    Context 'Tenant-wide VM placement CSV' {

        # Conditional by design: a tenant with no virtual machines, or a -Resume run
        # whose remaining subscriptions have none, legitimately produces no CSV. So
        # presence is not asserted - only that WHEN present it sits at the root under
        # the fixed name, and that it carries no un-obfuscated identifier.

        It 'when present, sits at the bundle root under the fixed name VMPlacement.csv' {
            $Csvs = @($script:EntryNames | Where-Object { $_ -like 'VMPlacement*.csv' })
            if ($Csvs.Count -eq 0)
            {
                Set-ItResult -Skipped -Because 'this bundle carries no VM placement CSV (a tenant with no VMs is a legitimate outcome)'
                return
            }
            $script:RootEntries | Should -Contain 'VMPlacement.csv' -Because 'a consumer binds to a fixed member name rather than globbing a timestamp'
            # The on-disk copy keeps its timestamp; the bundled copy must not.
            @($script:EntryNames | Where-Object { $_ -match '^VMPlacement_\d' }).Count |
                Should -Be 0 -Because 'the timestamped form belongs on local disk, not in the bundle'
        }

        It 'when present in an obfuscated bundle, exposes no raw ARM path in its identifier columns' {
            if ($script:RootEntries -notcontains 'VMPlacement.csv')
            {
                Set-ItResult -Skipped -Because 'no VMPlacement.csv in this bundle'
                return
            }

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $Archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $script:BundlePath).Path)
            try
            {
                $Entry = $Archive.Entries | Where-Object { $_.FullName -eq 'VMPlacement.csv' } | Select-Object -First 1
                $Reader = New-Object System.IO.StreamReader($Entry.Open())
                try { $Content = $Reader.ReadToEnd() } finally { $Reader.Dispose() }

                # RunSummary.log (a required outer-root member) is the independent
                # obfuscation-mode signal used below, read here from the same archive.
                $SummaryEntry = $Archive.Entries | Where-Object { $_.FullName -eq 'RunSummary.log' } | Select-Object -First 1
                $RunSummary = ''
                if ($null -ne $SummaryEntry)
                {
                    $SummaryReader = New-Object System.IO.StreamReader($SummaryEntry.Open())
                    try { $RunSummary = $SummaryReader.ReadToEnd() } finally { $SummaryReader.Dispose() }
                }
            }
            finally
            {
                $Archive.Dispose()
            }

            $Rows = @($Content | ConvertFrom-Csv)
            if ($Rows.Count -eq 0)
            {
                Set-ItResult -Skipped -Because 'the CSV has a header but no rows'
                return
            }

            # Mode comes from RunSummary.log's header, an independent signal, rather
            # than the Subscription column this test validates. Get-RunSummaryLogContent
            # writes 'Non-obfuscated run: ...' only for a non-obfuscated run and
            # 'Obfuscated run: ...' otherwise. Deriving the mode from the Subscription
            # column would let a whole-column obfuscation failure - every value a raw
            # name, so nothing matching ^(prod|nonprod)_ - masquerade as a non-obfuscated
            # bundle and skip the very leak this test exists to catch. Absent or
            # ambiguous header: fail closed to obfuscated, the stricter rule.
            $IsObfuscated = $RunSummary -notmatch 'Non-obfuscated run'
            if (-not $IsObfuscated)
            {
                Set-ItResult -Skipped -Because 'this is a non-obfuscated bundle, whose report already carries real names by design'
                return
            }

            # A full ARM resource path is never a legitimate value in these columns.
            foreach ($Column in @('Subscription', 'ResourceGroup', 'Name'))
            {
                @($Rows | Where-Object { $_.$Column -match '/subscriptions/' }).Count |
                    Should -Be 0 -Because ("{0} must not carry a raw ARM path in an obfuscated bundle" -f $Column)
            }

            # Every Subscription value should be a token in an obfuscated bundle.
            @($Rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Subscription) -and $_.Subscription -notmatch '^(prod|nonprod)_' }).Count |
                Should -Be 0 -Because 'obfuscation is deterministic, so a partially-tokenized column indicates a broken join'
        }
    }
}
