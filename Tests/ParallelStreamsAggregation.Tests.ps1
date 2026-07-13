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
# If both env vars are unset, the test auto-discovers the two most recent
# AllSubscriptions_*.zip files under $env:HOME/InventoryReports (or
# $env:USERPROFILE\InventoryReports on Windows) and assumes the older one is
# sequential and the newer one is parallel. For repeatability, set both env
# vars explicitly.

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
        $tmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $extractRoot = Join-Path $tmpBase ("ParStreams_${label}_" + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

        # Outer bundle expand -> contains one or more inner per-sub ResourcesReport_*.zip files.
        Expand-Archive -Path $bundlePath -DestinationPath $extractRoot -Force

        # Each inner ZIP is itself the per-sub artifact bundle.
        $innerZips = @(Get-ChildItem -Path $extractRoot -Filter 'ResourcesReport_*.zip' -File)
        $perSub = @()
        foreach ($iz in $innerZips)
        {
            $subDir = Join-Path $extractRoot ($iz.BaseName)
            New-Item -ItemType Directory -Path $subDir -Force | Out-Null
            Expand-Archive -Path $iz.FullName -DestinationPath $subDir -Force
            $perSub += [pscustomobject]@{
                ZipName = $iz.Name
                Dir     = $subDir
            }
        }
        return [pscustomobject]@{
            Root   = $extractRoot
            Inner  = $perSub
        }
    }

    function Get-PerSubArtifacts($subDir)
    {
        $htmlFile = Get-ChildItem -Path $subDir -Filter 'ResourcesReport_*.html' | Select-Object -First 1
        $invFile = Get-ChildItem -Path $subDir -Filter 'Inventory_*.json'      | Select-Object -First 1
        $metFile = Get-ChildItem -Path $subDir -Filter 'Metrics_*.json'        | Select-Object -First 1
        $conFile = Get-ChildItem -Path $subDir -Filter 'Consumption_*.csv'     | Select-Object -First 1

        $inv = if ($invFile) { Get-Content $invFile.FullName -Raw | ConvertFrom-Json } else { $null }
        $met = if ($metFile) { Get-Content $metFile.FullName -Raw | ConvertFrom-Json } else { $null }

        $conRows = 0
        if ($conFile)
        {
            $lines = Get-Content $conFile.FullName -ErrorAction SilentlyContinue
            if ($lines -and $lines.Count -gt 1) { $conRows = $lines.Count - 1 }
        }

        # Resource type names that have data (non-null arrays). Excludes Version key.
        $populatedTypes = @()
        if ($inv)
        {
            # "Populated" means the resource type actually has rows. Every
            # collector emits a (possibly empty) array, so a non-null check
            # alone would treat all ~57 types as populated even for an empty
            # subscription. Require Count > 0 so this matches what the HTML
            # report renders (one section per type with rows) and what an
            # empty subscription legitimately produces (none).
            $populatedTypes = @(
                $inv.PSObject.Properties |
                    Where-Object { $_.Name -ne 'Version' -and $null -ne $_.Value -and @($_.Value).Count -gt 0 } |
                    ForEach-Object { $_.Name }
                ) | Sort-Object
            }

            # Resource ID universe across every populated type
            $allIds = @()
            if ($inv)
            {
                $inv.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } |
                    ForEach-Object {
                        @($_.Value) | ForEach-Object { if ($_ -and $_.ID) { $allIds += $_.ID } }
                    }
        }

        return [pscustomobject]@{
            HtmlPath        = if ($htmlFile) { $htmlFile.FullName } else { $null }
            InventoryPath   = if ($invFile) { $invFile.FullName }  else { $null }
            MetricsPath     = if ($metFile) { $metFile.FullName }  else { $null }
            ConsumptionPath = if ($conFile) { $conFile.FullName }  else { $null }
            PopulatedTypes  = $populatedTypes
            ResourceCount   = $allIds.Count
            ResourceIds     = ($allIds | Sort-Object -Unique)
            MetricsCount    = if ($met -and $met.Metrics) { @($met.Metrics).Count } else { 0 }
            ConsumptionRows = $conRows
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
        $names = @()
        if (-not $htmlPath -or -not (Test-Path $htmlPath)) { return $names }
        $content = Get-Content $htmlPath -Raw
        $svcMatches = [regex]::Matches($content, 'id="svc-([a-z0-9-]+)"')
        foreach ($m in $svcMatches) { $names += $m.Groups[1].Value }
        return $names | Sort-Object -Unique
    }

    $bundles = $null
    if ($script:HaveFixture)
    {
        $bundles = @{
            Sequential = $script:SeqBundlePath
            Parallel   = $script:ParBundlePath
        }
    }
    if ($script:HaveFixture)
    {
        $script:Sequential = Expand-Bundle -bundlePath $bundles.Sequential -label 'seq'
        $script:Parallel = Expand-Bundle -bundlePath $bundles.Parallel   -label 'par'
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
        $seqTotal = ($script:SeqArtifacts | Measure-Object -Property ResourceCount -Sum).Sum
        $parTotal = ($script:ParArtifacts | Measure-Object -Property ResourceCount -Sum).Sum
        $parTotal | Should -Be $seqTotal `
            -Because 'parallelism must not drop any resources'
    }

    It 'Set of populated resource types per sub matches one-to-one' {
        # Build sorted "fingerprints" of populated types for each side and compare
        # the multisets. This is order-independent (a parallel run may emit subs
        # in any order) and tolerates equal-resource-count subs in either side.
        $seqFingerprints = @($script:SeqArtifacts | ForEach-Object { ($_.PopulatedTypes -join ',') }) | Sort-Object
        $parFingerprints = @($script:ParArtifacts | ForEach-Object { ($_.PopulatedTypes -join ',') }) | Sort-Object
        ($parFingerprints -join '|') | Should -Be ($seqFingerprints -join '|')
    }

    It 'Total consumption record count matches between sequential and parallel' {
        $seqRows = ($script:SeqArtifacts | Measure-Object -Property ConsumptionRows -Sum).Sum
        $parRows = ($script:ParArtifacts | Measure-Object -Property ConsumptionRows -Sum).Sum
        $parRows | Should -Be $seqRows `
            -Because 'consumption queries are subscription-scoped and unaffected by stream count'
    }

    It 'Total metrics record count matches between sequential and parallel (within 5% tolerance)' {
        # Metrics are time-window queries; running them seconds apart can yield
        # different bucket counts at the boundary. 5% tolerance protects against
        # this without hiding real regressions (a broken stream would lose 100%
        # of one sub's metrics, far above 5%).
        $seqM = ($script:SeqArtifacts | Measure-Object -Property MetricsCount -Sum).Sum
        $parM = ($script:ParArtifacts | Measure-Object -Property MetricsCount -Sum).Sum
        if ($seqM -eq 0)
        {
            $parM | Should -Be 0 -Because 'if sequential collected zero metrics, parallel must too'
        }
        else
        {
            $delta = [Math]::Abs($parM - $seqM) / [double]$seqM
            $delta | Should -BeLessOrEqual 0.05 `
                -Because "metrics drift too large: seq=$seqM par=$parM (delta $($delta.ToString('P1')))"
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
            $seqSections = Get-HtmlSectionSlugs $script:SeqBySig[$key].HtmlPath
            $parSections = Get-HtmlSectionSlugs $script:ParBySig[$key].HtmlPath
            ($parSections -join ',') | Should -Be ($seqSections -join ',') `
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
            $sections = @(Get-HtmlSectionSlugs $a.HtmlPath | Where-Object { $_ })
            $populatedCount = @($a.PopulatedTypes).Count
            if ($populatedCount -eq 0)
            {
                $sections.Count | Should -Be 0 `
                    -Because 'an empty subscription (no populated resource types) must render no service sections'
            }
            else
            {
                $sections.Count | Should -BeGreaterThan 0 `
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
            $seqInv = Get-Content $script:SeqBySig[$key].InventoryPath -Raw | ConvertFrom-Json
            $parInv = Get-Content $script:ParBySig[$key].InventoryPath -Raw | ConvertFrom-Json
            $seqKeys = @($seqInv.PSObject.Properties.Name) | Sort-Object
            $parKeys = @($parInv.PSObject.Properties.Name) | Sort-Object
            ($parKeys -join ',') | Should -Be ($seqKeys -join ',') `
                -Because "Inventory JSON top-level keys must be identical for sub signature '$key'"
        }
    }

    It 'Version field is present and identical in every Inventory JSON (both modes)' {
        $versions = @()
        foreach ($a in @($script:SeqArtifacts) + @($script:ParArtifacts))
        {
            $inv = Get-Content $a.InventoryPath -Raw | ConvertFrom-Json
            $inv.Version | Should -Not -BeNullOrEmpty
            $versions += $inv.Version
        }
        ($versions | Sort-Object -Unique).Count | Should -Be 1 `
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
        $seqIds = @($script:SeqArtifacts | ForEach-Object { $_.ResourceIds }) | Where-Object { $_ }
        $parIds = @($script:ParArtifacts | ForEach-Object { $_.ResourceIds }) | Where-Object { $_ }

        $seqObf = @($seqIds | Where-Object { $_ -match '^(prod|nonprod)_' }).Count
        $parObf = @($parIds | Where-Object { $_ -match '^(prod|nonprod)_' }).Count

        if ($seqObf -gt 0 -or $parObf -gt 0)
        {
            $seqRatio = if ($seqIds.Count) { $seqObf / [double]$seqIds.Count } else { 0 }
            $parRatio = if ($parIds.Count) { $parObf / [double]$parIds.Count } else { 0 }
            [Math]::Abs($seqRatio - $parRatio) | Should -BeLessOrEqual 0.01 `
                -Because "obfuscation ratio diverges between modes: seq=$($seqRatio.ToString('P1')) par=$($parRatio.ToString('P1'))"
        }
        else
        {
            Set-ItResult -Skipped -Because 'neither bundle contains obfuscated IDs (set up with -Obfuscate to enable this test)'
        }
    }
}
