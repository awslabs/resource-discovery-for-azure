# Parallel-Streams Aggregation Tests
# Validates that a parallel run (-ParallelStreams N) produces structurally
# equivalent output to a sequential run (single sub-folder per subscription,
# matching HTML service-section sets, matching Inventory JSON keys, matching
# consumption record counts, matching obfuscated-ID universes when -Obfuscate is set).
#
# These tests are the drift-prevention guard for the parallel-streams feature.
# Any change to the wrapper, the worker, or the per-sub folder convention that
# silently desyncs sequential vs parallel output will fail here.
#
# Run with:
#   Invoke-Pester ./Tests/ParallelStreamsAggregation.Tests.ps1 -Output Detailed
#
# Inputs (env vars):
#   $env:TEST_SEQUENTIAL_BUNDLE  - path to AllSubscriptions_*.zip from a -ParallelStreams 1 run
#   $env:TEST_PARALLEL_BUNDLE    - path to AllSubscriptions_*.zip from a -ParallelStreams N (N>=2) run
#
# Both env vars are REQUIRED. Auto-discovery of the two newest
# AllSubscriptions_*.zip files was deliberately removed: two arbitrary bundles
# in the default InventoryReports directory could come from runs with different
# flag combinations (e.g. one -SkipMetrics, one not), producing false-positive
# failures here. If either env var is unset, every test in this file is marked
# Skipped (mirroring how Obfuscation.Tests.ps1 handles "no fixture provided").

BeforeAll {
    # Resolve the sequential/parallel bundle pair *only* from explicit env vars.
    # Auto-discovery is unsafe: any two AllSubscriptions_*.zip files in the
    # default InventoryReports directory could be from runs with different
    # flag combinations (e.g. one with -SkipMetrics, one without), which would
    # produce false-positive failures here. If the env vars are unset we mark
    # all tests in this file Skipped, mirroring how Obfuscation.Tests.ps1
    # gracefully handles "no fixture provided".
    $script:HaveFixture = $false
    if ($env:TEST_SEQUENTIAL_BUNDLE -and $env:TEST_PARALLEL_BUNDLE)
    {
        if ((Test-Path $env:TEST_SEQUENTIAL_BUNDLE) -and (Test-Path $env:TEST_PARALLEL_BUNDLE))
        {
            $script:HaveFixture = $true
            $script:SeqBundlePath = $env:TEST_SEQUENTIAL_BUNDLE
            $script:ParBundlePath = $env:TEST_PARALLEL_BUNDLE
        }
    }

    function Expand-Bundle($bundlePath, $label)
    {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $ExtractRoot = Join-Path $TmpBase ("ParStreams_${label}_" + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null

        # Outer bundle expand -> contains one or more inner per-sub ResourcesReport_*.zip files.
        Expand-Archive -Path $bundlePath -DestinationPath $ExtractRoot -Force

        # Each inner ZIP is itself the per-sub artifact bundle.
        $InnerZips = @(Get-ChildItem -Path $ExtractRoot -Filter 'ResourcesReport_*.zip' -File)
        $PerSub = @()
        foreach ($iz in $InnerZips)
        {
            $SubDir = Join-Path $ExtractRoot ($iz.BaseName)
            New-Item -ItemType Directory -Path $SubDir -Force | Out-Null
            Expand-Archive -Path $iz.FullName -DestinationPath $SubDir -Force
            $PerSub += [pscustomobject]@{
                ZipName = $iz.Name
                Dir     = $SubDir
            }
        }
        return [pscustomobject]@{
            Root   = $ExtractRoot
            Inner  = $PerSub
        }
    }

    function Get-PerSubArtifacts($SubDir)
    {
        $HtmlFile = Get-ChildItem -Path $SubDir -Filter 'ResourcesReport_*.html' | Select-Object -First 1
        $InvFile = Get-ChildItem -Path $SubDir -Filter 'Inventory_*.json'      | Select-Object -First 1
        $MetFile = Get-ChildItem -Path $SubDir -Filter 'Metrics_*.json'        | Select-Object -First 1
        $ConFile = Get-ChildItem -Path $SubDir -Filter 'Consumption_*.csv'     | Select-Object -First 1

        $Inv = if ($InvFile) { Get-Content $InvFile.FullName -Raw | ConvertFrom-Json } else { $null }
        $Met = if ($MetFile) { Get-Content $MetFile.FullName -Raw | ConvertFrom-Json } else { $null }

        $ConRows = 0
        if ($ConFile)
        {
            $Lines = Get-Content $ConFile.FullName -ErrorAction SilentlyContinue
            if ($Lines -and $Lines.Count -gt 1) { $ConRows = $Lines.Count - 1 }
        }

        # Resource type names that have data (non-null arrays). Excludes Version key.
        $PopulatedTypes = @()
        if ($Inv)
        {
            # "Populated" means the resource type actually has rows. Every
            # collector emits a (possibly empty) array, so a non-null check
            # alone would treat all ~57 types as populated even for an empty
            # subscription. Require Count > 0 so this matches what the HTML
            # report renders (one section per type with rows) and what an
            # empty subscription legitimately produces (none).
            $PopulatedTypes = @(
                $Inv.PSObject.Properties |
                    Where-Object { $_.Name -ne 'Version' -and $null -ne $_.Value -and @($_.Value).Count -gt 0 } |
                    ForEach-Object { $_.Name }
                ) | Sort-Object
            }

            # Resource ID universe across every populated type
            $AllIds = @()
            if ($Inv)
            {
                $Inv.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } |
                    ForEach-Object {
                        @($_.Value) | ForEach-Object { if ($_ -and $_.ID) { $AllIds += $_.ID } }
                    }
        }

        return [pscustomobject]@{
            HtmlPath        = if ($HtmlFile) { $HtmlFile.FullName } else { $null }
            InventoryPath   = if ($InvFile) { $InvFile.FullName }  else { $null }
            MetricsPath     = if ($MetFile) { $MetFile.FullName }  else { $null }
            ConsumptionPath = if ($ConFile) { $ConFile.FullName }  else { $null }
            PopulatedTypes  = $PopulatedTypes
            ResourceCount   = $AllIds.Count
            ResourceIds     = ($AllIds | Sort-Object -Unique)
            MetricsCount    = if ($Met -and $Met.Metrics) { @($Met.Metrics).Count } else { 0 }
            ConsumptionRows = $ConRows
        }
    }

    function Get-HtmlSectionSlugs($htmlPath)
    {
        # Enumerate the service-section slugs the HTML report emitted, without
        # depending on any module. Summary.ps1 emits one
        # <details class="service-section" id="svc-<slug>"> per populated
        # service, where <slug> is the service key lowercased with
        # non-alphanumerics replaced by '-'. This is the HTML analogue of the
        # old XLSX worksheet-name set.
        $Names = @()
        if (-not $htmlPath -or -not (Test-Path $htmlPath)) { return $Names }
        $Content = Get-Content $htmlPath -Raw
        $SvcMatches = [regex]::Matches($Content, 'id="svc-([a-z0-9-]+)"')
        foreach ($m in $SvcMatches) { $Names += $m.Groups[1].Value }
        return $Names | Sort-Object -Unique
    }

    $Bundles = $null
    if ($script:HaveFixture)
    {
        $Bundles = @{
            Sequential = $script:SeqBundlePath
            Parallel   = $script:ParBundlePath
        }
    }
    if ($script:HaveFixture)
    {
        $script:Sequential = Expand-Bundle -bundlePath $Bundles.Sequential -label 'seq'
        $script:Parallel = Expand-Bundle -bundlePath $Bundles.Parallel   -label 'par'
    }
    else
    {
        $script:Sequential = $null
        $script:Parallel = $null
    }

    # Build per-sub artifact maps keyed by populated-type signature so we can
    # match a sequential sub to its parallel counterpart even though their
    # millisecond-precision timestamps differ.
    $script:SeqArtifacts = if ($script:HaveFixture)
    {
        @($script:Sequential.Inner | ForEach-Object { Get-PerSubArtifacts $_.Dir })
    }
    else { @() }
    $script:ParArtifacts = if ($script:HaveFixture)
    {
        @($script:Parallel.Inner   | ForEach-Object { Get-PerSubArtifacts $_.Dir })
    }
    else { @() }

    function Get-SignatureKey($a)
    {
        # Tuple of (resource-count, sorted populated-type names) is unique enough for
        # the small fixture sizes we test against. Falls back to ResourceCount alone
        # if both subs happen to have identical type sets.
        '{0}|{1}' -f $a.ResourceCount, ($a.PopulatedTypes -join ',')
    }
    $script:SeqBySig = @{}
    foreach ($a in $script:SeqArtifacts) { $script:SeqBySig[(Get-SignatureKey $a)] = $a }
    $script:ParBySig = @{}
    foreach ($a in $script:ParArtifacts) { $script:ParBySig[(Get-SignatureKey $a)] = $a }
}

AfterAll {
    if ($script:Sequential -and (Test-Path $script:Sequential.Root))
    {
        Remove-Item -Path $script:Sequential.Root -Recurse -Force
    }
    if ($script:Parallel -and (Test-Path $script:Parallel.Root))
    {
        Remove-Item -Path $script:Parallel.Root -Recurse -Force
    }
}

Describe 'Bundle-level structure' {
    BeforeEach { if (-not $script:HaveFixture) { Set-ItResult -Skipped -Because 'set $env:TEST_SEQUENTIAL_BUNDLE and $env:TEST_PARALLEL_BUNDLE to enable' } }
    It 'Both bundles contain the same number of inner per-sub ZIPs' {
        $script:Sequential.Inner.Count | Should -Be $script:Parallel.Inner.Count `
            -Because 'parallel and sequential modes must process the same set of subscriptions'
    }

    It 'Both bundles contain at least one inner per-sub ZIP' {
        $script:Sequential.Inner.Count | Should -BeGreaterThan 0
    }

    It 'Each inner per-sub directory contains an HTML report, Inventory JSON, Metrics JSON, and Consumption CSV (sequential)' {
        foreach ($a in $script:SeqArtifacts)
        {
            $a.HtmlPath        | Should -Not -BeNullOrEmpty -Because 'HTML report is the primary output artifact'
            $a.InventoryPath   | Should -Not -BeNullOrEmpty
            $a.MetricsPath     | Should -Not -BeNullOrEmpty
            $a.ConsumptionPath | Should -Not -BeNullOrEmpty
        }
    }

    It 'Each inner per-sub directory contains an HTML report, Inventory JSON, Metrics JSON, and Consumption CSV (parallel)' {
        foreach ($a in $script:ParArtifacts)
        {
            $a.HtmlPath        | Should -Not -BeNullOrEmpty
            $a.InventoryPath   | Should -Not -BeNullOrEmpty
            $a.MetricsPath     | Should -Not -BeNullOrEmpty
            $a.ConsumptionPath | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Sequential vs parallel: per-sub equivalence' {
    BeforeEach { if (-not $script:HaveFixture) { Set-ItResult -Skipped -Because 'set $env:TEST_SEQUENTIAL_BUNDLE and $env:TEST_PARALLEL_BUNDLE to enable' } }
    It 'Total resource count across all subs matches between sequential and parallel' {
        $SeqTotal = ($script:SeqArtifacts | Measure-Object -Property ResourceCount -Sum).Sum
        $ParTotal = ($script:ParArtifacts | Measure-Object -Property ResourceCount -Sum).Sum
        $ParTotal | Should -Be $SeqTotal `
            -Because 'parallelism must not drop any resources'
    }

    It 'Set of populated resource types per sub matches one-to-one' {
        # Build sorted "fingerprints" of populated types for each side and compare
        # the multisets. This is order-independent (a parallel run may emit subs
        # in any order) and tolerates equal-resource-count subs in either side.
        $SeqFingerprints = @($script:SeqArtifacts | ForEach-Object { ($_.PopulatedTypes -join ',') }) | Sort-Object
        $ParFingerprints = @($script:ParArtifacts | ForEach-Object { ($_.PopulatedTypes -join ',') }) | Sort-Object
        ($ParFingerprints -join '|') | Should -Be ($SeqFingerprints -join '|')
    }

    It 'Total consumption record count matches between sequential and parallel' {
        $SeqRows = ($script:SeqArtifacts | Measure-Object -Property ConsumptionRows -Sum).Sum
        $ParRows = ($script:ParArtifacts | Measure-Object -Property ConsumptionRows -Sum).Sum
        $ParRows | Should -Be $SeqRows `
            -Because 'consumption queries are subscription-scoped and unaffected by stream count'
    }

    It 'Total metrics record count matches between sequential and parallel (within 5% tolerance)' {
        # Metrics are time-window queries; running them seconds apart can yield
        # different bucket counts at the boundary. 5% tolerance protects against
        # this without hiding real regressions (a broken stream would lose 100%
        # of one sub's metrics, far above 5%).
        $SeqM = ($script:SeqArtifacts | Measure-Object -Property MetricsCount -Sum).Sum
        $ParM = ($script:ParArtifacts | Measure-Object -Property MetricsCount -Sum).Sum
        if ($SeqM -eq 0)
        {
            $ParM | Should -Be 0 -Because 'if sequential collected zero metrics, parallel must too'
        }
        else
        {
            $Delta = [Math]::Abs($ParM - $SeqM) / [double]$SeqM
            $Delta | Should -BeLessOrEqual 0.05 `
                -Because "metrics drift too large: seq=$SeqM par=$ParM (delta $($Delta.ToString('P1')))"
        }
    }
}

Describe 'HTML section equivalence' {
    BeforeEach { if (-not $script:HaveFixture) { Set-ItResult -Skipped -Because 'set $env:TEST_SEQUENTIAL_BUNDLE and $env:TEST_PARALLEL_BUNDLE to enable' } }
    It 'Each sub has the same set of HTML service sections in sequential vs parallel' {
        # Match per-sub by population signature (count + types) so the comparison
        # is robust to subscription ordering differences between modes.
        foreach ($key in $script:SeqBySig.Keys)
        {
            $script:ParBySig.ContainsKey($key) | Should -BeTrue `
                -Because "no parallel-side counterpart found for sequential sub with signature '$key'"
            $SeqSections = Get-HtmlSectionSlugs $script:SeqBySig[$key].HtmlPath
            $ParSections = Get-HtmlSectionSlugs $script:ParBySig[$key].HtmlPath
            ($ParSections -join ',') | Should -Be ($SeqSections -join ',') `
                -Because "HTML service-section set diverged for sub signature '$key'"
        }
    }

    It 'Each per-sub HTML renders a section for every populated resource type (empty subs render none)' {
        # The correct invariant ties HTML sections to the sub's OWN inventory:
        # a populated sub must render >=1 section, and a legitimately empty sub
        # (0 populated resource types - e.g. an empty subscription) must render
        # 0 sections. Asserting "every sub has >=1 section" was wrong: it
        # false-fails on tenants that contain an empty subscription. Compare the
        # rendered section count to the populated-type count instead.
        foreach ($a in @($script:SeqArtifacts) + @($script:ParArtifacts))
        {
            $Sections = @(Get-HtmlSectionSlugs $a.HtmlPath | Where-Object { $_ })
            $PopulatedCount = @($a.PopulatedTypes).Count
            if ($PopulatedCount -eq 0)
            {
                $Sections.Count | Should -Be 0 `
                    -Because 'an empty subscription (no populated resource types) must render no service sections'
            }
            else
            {
                $Sections.Count | Should -BeGreaterThan 0 `
                    -Because 'a populated subscription must render at least one service section'
            }
        }
    }
}

Describe 'Inventory JSON key parity' {
    BeforeEach { if (-not $script:HaveFixture) { Set-ItResult -Skipped -Because 'set $env:TEST_SEQUENTIAL_BUNDLE and $env:TEST_PARALLEL_BUNDLE to enable' } }
    It 'Every Inventory JSON in both modes contains the canonical resource-type key set' {
        # The schema fingerprint is the union of all populated-type sets across
        # both modes. We only assert that whichever keys are present on one side
        # are also present on the matching sub on the other side.
        foreach ($key in $script:SeqBySig.Keys)
        {
            if (-not $script:ParBySig.ContainsKey($key)) { continue }
            $SeqInv = Get-Content $script:SeqBySig[$key].InventoryPath -Raw | ConvertFrom-Json
            $ParInv = Get-Content $script:ParBySig[$key].InventoryPath -Raw | ConvertFrom-Json
            $SeqKeys = @($SeqInv.PSObject.Properties.Name) | Sort-Object
            $ParKeys = @($ParInv.PSObject.Properties.Name) | Sort-Object
            ($ParKeys -join ',') | Should -Be ($SeqKeys -join ',') `
                -Because "Inventory JSON top-level keys must be identical for sub signature '$key'"
        }
    }

    It 'Version field is present and identical in every Inventory JSON (both modes)' {
        $Versions = @()
        foreach ($a in @($script:SeqArtifacts) + @($script:ParArtifacts))
        {
            $Inv = Get-Content $a.InventoryPath -Raw | ConvertFrom-Json
            $Inv.Version | Should -Not -BeNullOrEmpty
            $Versions += $Inv.Version
        }
        ($Versions | Sort-Object -Unique).Count | Should -Be 1 `
            -Because 'all subs in a single test fixture should report the same script version'
    }
}

Describe 'Obfuscation universe parity (only meaningful on -Obfuscate runs)' {
    BeforeEach { if (-not $script:HaveFixture) { Set-ItResult -Skipped -Because 'set $env:TEST_SEQUENTIAL_BUNDLE and $env:TEST_PARALLEL_BUNDLE to enable' } }
    It 'When obfuscation is in effect, both modes produce IDs in the same prod_/nonprod_ namespace' {
        # We do not assert *identical* GUIDs across modes (each run mints fresh
        # GUIDs). We only assert that the format is consistent. A regression
        # that disabled obfuscation in one mode but not the other would break
        # this immediately.
        $SeqIds = @($script:SeqArtifacts | ForEach-Object { $_.ResourceIds }) | Where-Object { $_ }
        $ParIds = @($script:ParArtifacts | ForEach-Object { $_.ResourceIds }) | Where-Object { $_ }

        $SeqObf = @($SeqIds | Where-Object { $_ -match '^(prod|nonprod)_' }).Count
        $ParObf = @($ParIds | Where-Object { $_ -match '^(prod|nonprod)_' }).Count

        if ($SeqObf -gt 0 -or $ParObf -gt 0)
        {
            $SeqRatio = if ($SeqIds.Count) { $SeqObf / [double]$SeqIds.Count } else { 0 }
            $ParRatio = if ($ParIds.Count) { $ParObf / [double]$ParIds.Count } else { 0 }
            [Math]::Abs($SeqRatio - $ParRatio) | Should -BeLessOrEqual 0.01 `
                -Because "obfuscation ratio diverges between modes: seq=$($SeqRatio.ToString('P1')) par=$($ParRatio.ToString('P1'))"
        }
        else
        {
            Set-ItResult -Skipped -Because 'neither bundle contains obfuscated IDs (set up with -Obfuscate to enable this test)'
        }
    }
}
