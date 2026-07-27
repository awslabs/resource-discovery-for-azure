# Support-log bundle collection tests (New-RdaSupportLogBundle)
#
# Offline, self-contained unit tests for the support-log collector that gathers
# the LOCAL diagnostic logs a run leaves behind into one zip to hand to support.
# It lives in Functions/RunAllSubscriptions.Functions.ps1 - a definitions-only
# file with NO top-level side effects - so we dot-source it wholesale (same as
# RunAllSubscriptionsReconciliation.Tests.ps1). No Azure, no wrapper run: each
# test builds a synthetic InventoryRoot on disk, invokes the function, and
# inspects the produced zip with the cross-platform System.IO.Compression API.
#
# The single most important assertion is the SECURITY one: the obfuscation
# dictionary (ObfuscationDictionary_* / Full_*) - the de-obfuscation reveal key -
# must NEVER be collected into a bundle that is meant to be handed to support.
#
# Run with: Invoke-Pester ./Tests/SupportLogBundle.Tests.ps1 -Output Detailed

BeforeAll {
    $script:FunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1'
    if (-not (Test-Path $script:FunctionsPath))
    {
        throw "Could not find shared functions file at $script:FunctionsPath"
    }
    . $script:FunctionsPath

    # Guard: fail loudly here if the function is renamed/removed rather than with
    # a confusing "command not found" mid-test.
    foreach ($Fn in @('New-RdaSupportLogBundle', 'Test-ZipArchiveEntry'))
    {
        if (-not (Get-Command $Fn -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Expected function '$Fn' to be defined by $script:FunctionsPath, but it was not. Has it been renamed or removed?"
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestRoot = Join-Path $TmpBase ("SupportLogBundleTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

    # Return the (root-relative) entry names inside a zip.
    function Get-ZipEntryNames([string]$ZipPath)
    {
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try { return @($Archive.Entries | Select-Object -ExpandProperty FullName) }
        finally { $Archive.Dispose() }
    }

    # Build a representative InventoryRoot: wrapper logs at the top + one per-sub
    # ResourcesReport folder holding the four per-sub logs AND the two files that
    # must never be collected (dictionary + full inventory).
    function New-FakeInventoryRoot([string]$Base)
    {
        $Root = Join-Path $Base ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'RunAllSubscriptions_transcript_2026-07-24_10-00-00.txt') -Value 'transcript'
        Set-Content -LiteralPath (Join-Path $Root 'RunAllSubscriptions_failures_2026-07-24_10-00-00_ab12.log') -Value 'failures'
        Set-Content -LiteralPath (Join-Path $Root 'RunAllSubscriptions_diagnostics_2026-07-24_10-00-00_cd34.log') -Value 'access-verdict'
        Set-Content -LiteralPath (Join-Path $Root 'RunSummary_2026-07-24_10-00-00.log') -Value 'runsummary'
        Set-Content -LiteralPath (Join-Path $Root 'MainSummary_2026-07-24_10-00-00.html') -Value '<html>'
        $Sub = Join-Path $Root 'ResourcesReport202607241000000000abc'
        New-Item -ItemType Directory -Path $Sub -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Sub 'Diagnostics_ResourcesReport_202607241000000000abc.log') -Value 'scrubbed'
        Set-Content -LiteralPath (Join-Path $Sub 'DebugLog_ResourcesReport_202607241000000000abc_subid.log') -Value 'debug'
        Set-Content -LiteralPath (Join-Path $Sub 'ErrorLog_ResourcesReport_202607241000000000abc_subid.log') -Value 'errors'
        Set-Content -LiteralPath (Join-Path $Sub 'Transcript_Log_ResourcesReport_202607241000000000abc.txt') -Value 'inner transcript'
        Set-Content -LiteralPath (Join-Path $Sub 'ObfuscationDictionary_202607241000000000abc.json') -Value 'REVEAL KEY - MUST NOT SHIP'
        Set-Content -LiteralPath (Join-Path $Sub 'Full_Inventory_202607241000000000abc.json') -Value 'raw inventory - MUST NOT SHIP'
        return $Root
    }
}

AfterAll {
    if ($script:TestRoot -and (Test-Path $script:TestRoot))
    {
        Remove-Item -Path $script:TestRoot -Recurse -Force
    }
}

Describe 'New-RdaSupportLogBundle' {

    It 'collects wrapper + per-subscription logs and writes a MANIFEST' {
        $Root = New-FakeInventoryRoot $script:TestRoot
        $Bundle = New-RdaSupportLogBundle -InventoryRoot $Root
        $Bundle | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $Bundle | Should -BeTrue
        $Names = Get-ZipEntryNames $Bundle

        $Names | Should -Contain 'MANIFEST.txt'
        $Names | Should -Contain 'RunAllSubscriptions_transcript_2026-07-24_10-00-00.txt'
        $Names | Should -Contain 'RunAllSubscriptions_failures_2026-07-24_10-00-00_ab12.log'
        $Names | Should -Contain 'RunAllSubscriptions_diagnostics_2026-07-24_10-00-00_cd34.log'
        $Names | Should -Contain 'RunSummary_2026-07-24_10-00-00.log'
    }

    It 'NEVER collects the obfuscation dictionary or full inventory (reveal key)' {
        $Root = New-FakeInventoryRoot $script:TestRoot
        $Bundle = New-RdaSupportLogBundle -InventoryRoot $Root
        $Names = Get-ZipEntryNames $Bundle

        @($Names | Where-Object { $_ -like '*ObfuscationDictionary_*' }) | Should -BeNullOrEmpty
        @($Names | Where-Object { $_ -like '*Full_*' }) | Should -BeNullOrEmpty
    }

    It 'groups per-subscription logs under their ResourcesReport folder' {
        $Root = New-FakeInventoryRoot $script:TestRoot
        $Bundle = New-RdaSupportLogBundle -InventoryRoot $Root
        $Names = Get-ZipEntryNames $Bundle

        # Entry separators can be / or \ depending on the host; match either.
        @($Names | Where-Object { $_ -match 'ResourcesReport202607241000000000abc[\\/]Diagnostics_' }) | Should -Not -BeNullOrEmpty
        @($Names | Where-Object { $_ -match 'ResourcesReport202607241000000000abc[\\/]DebugLog_' }) | Should -Not -BeNullOrEmpty
        @($Names | Where-Object { $_ -match 'ResourcesReport202607241000000000abc[\\/]ErrorLog_' }) | Should -Not -BeNullOrEmpty
        @($Names | Where-Object { $_ -match 'ResourcesReport202607241000000000abc[\\/]Transcript_Log_' }) | Should -Not -BeNullOrEmpty
    }

    It 'excludes MainSummary by default and includes it with -IncludeMainSummary' {
        $Root = New-FakeInventoryRoot $script:TestRoot

        $Default = Get-ZipEntryNames (New-RdaSupportLogBundle -InventoryRoot $Root)
        $Default | Should -Not -Contain 'MainSummary_2026-07-24_10-00-00.html'

        $WithMain = Get-ZipEntryNames (New-RdaSupportLogBundle -InventoryRoot $Root -IncludeMainSummary -DestinationPath (Join-Path $Root 'withmain.zip'))
        $WithMain | Should -Contain 'MainSummary_2026-07-24_10-00-00.html'
    }

    It 'honors -SinceTime: excludes files older than the window' {
        $Root = New-FakeInventoryRoot $script:TestRoot
        # Backdate the transcript well before the window; leave the failures log recent.
        $Transcript = Join-Path $Root 'RunAllSubscriptions_transcript_2026-07-24_10-00-00.txt'
        (Get-Item -LiteralPath $Transcript).LastWriteTime = (Get-Date).AddDays(-2)

        $Bundle = New-RdaSupportLogBundle -InventoryRoot $Root -SinceTime (Get-Date).AddHours(-1) -DestinationPath (Join-Path $Root 'since.zip')
        $Bundle | Should -Not -BeNullOrEmpty
        $Names = Get-ZipEntryNames $Bundle
        $Names | Should -Not -Contain 'RunAllSubscriptions_transcript_2026-07-24_10-00-00.txt'
        $Names | Should -Contain 'RunAllSubscriptions_failures_2026-07-24_10-00-00_ab12.log'
    }

    It 'returns $null (no zip) when nothing matches the -SinceTime window' {
        $Root = New-FakeInventoryRoot $script:TestRoot
        # New-RdaSupportLogBundle is a simple (non-advanced) function, so it does
        # not honor -WarningAction; redirect the warning stream (3>) to keep the
        # expected "nothing to collect" warning out of the test output instead.
        $Bundle = New-RdaSupportLogBundle -InventoryRoot $Root -SinceTime (Get-Date).AddDays(1) 3>$null
        $Bundle | Should -BeNullOrEmpty
    }

    It 'returns $null for an empty inventory root' {
        $Empty = Join-Path $script:TestRoot ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Empty -Force | Out-Null
        $Bundle = New-RdaSupportLogBundle -InventoryRoot $Empty 3>$null
        $Bundle | Should -BeNullOrEmpty
    }

    It 'returns $null for a non-existent inventory root' {
        $Missing = Join-Path $script:TestRoot 'does-not-exist'
        $Bundle = New-RdaSupportLogBundle -InventoryRoot $Missing 3>$null
        $Bundle | Should -BeNullOrEmpty
    }

    It 'Test-ZipArchiveEntry detects present, absent, and missing-archive cases' {
        $Root = New-FakeInventoryRoot $script:TestRoot
        $Bundle = New-RdaSupportLogBundle -InventoryRoot $Root
        Test-ZipArchiveEntry -ZipPath $Bundle -EntryName 'MANIFEST.txt' | Should -BeTrue
        Test-ZipArchiveEntry -ZipPath $Bundle -EntryName 'NoSuchEntry.log' | Should -BeFalse
        Test-ZipArchiveEntry -ZipPath (Join-Path $script:TestRoot 'no-such-archive.zip') -EntryName 'MANIFEST.txt' | Should -BeFalse
    }
}
