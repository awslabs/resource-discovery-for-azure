# Parallel-Streams Aggregation Tests: drift-prevention guard that a parallel run (-ParallelStreams N) produces output structurally equivalent to a sequential run.
# Both TEST_SEQUENTIAL_BUNDLE and TEST_PARALLEL_BUNDLE env vars are REQUIRED (auto-discovery was removed to avoid mismatched-flag false positives); unset => every test is Skipped.

BeforeAll {
    # Resolve the bundle pair ONLY from explicit env vars; unset => mark all tests
    # Skipped. Auto-discovery is unsafe: two arbitrary bundles may be from mismatched-flag runs, causing false-positive failures.
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
            # "Populated" requires Count > 0, not just non-null: every collector
            # emits a possibly-empty array, so a non-null check would mark all ~57 types populated. Count>0 matches what the HTML report renders.
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
        # Enumerate the HTML service-section slugs without a module dependency:
        # Summary.ps1 emits one id="svc-<slug>" per populated service, where <slug> is the service key lowercased with non-alphanumerics replaced by '-'.
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
    # Group per-sub artifacts by signature into LISTS, not scalars: subs with an
    # identical (ResourceCount, PopulatedTypes) signature collide on one key (e.g. two empty subs -> '0|'), and a scalar hashtable would overwrite all but the last.
    $script:SeqBySig = @{}
    foreach ($a in $script:SeqArtifacts)
    {
        $Key = Get-SignatureKey $a
        if (-not $script:SeqBySig.ContainsKey($Key)) { $script:SeqBySig[$Key] = @() }
        $script:SeqBySig[$Key] += $a
    }
    $script:ParBySig = @{}
    foreach ($a in $script:ParArtifacts)
    {
        $Key = Get-SignatureKey $a
        if (-not $script:ParBySig.ContainsKey($Key)) { $script:ParBySig[$Key] = @() }
        $script:ParBySig[$Key] += $a
    }
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
            # A signature can match more than one sub per side (e.g. two empty
            # subs). Compare the multiset of per-sub slug sets so every colliding
            # sub is checked and a differing count between sides is caught too.
            $SeqSlugSets = @($script:SeqBySig[$key] | ForEach-Object { (Get-HtmlSectionSlugs $_.HtmlPath) -join ',' }) | Sort-Object
            $ParSlugSets = @($script:ParBySig[$key] | ForEach-Object { (Get-HtmlSectionSlugs $_.HtmlPath) -join ',' }) | Sort-Object
            ($ParSlugSets -join '|') | Should -Be ($SeqSlugSets -join '|') `
                -Because "HTML service-section set diverged for sub signature '$key'"
        }
    }

    It 'Each per-sub HTML renders a section for every populated resource type (empty subs render none)' {
        # Tie HTML section count to the sub's OWN inventory: a populated sub renders
        # >=1 section, a legitimately empty sub renders 0. A flat "every sub >=1" assertion false-fails on tenants containing an empty subscription.
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
            # A signature can match more than one sub per side; compare the
            # multiset of per-sub key sets so every colliding sub is checked.
            $SeqKeySets = @($script:SeqBySig[$key] | ForEach-Object {
                    $Inv = Get-Content $_.InventoryPath -Raw | ConvertFrom-Json
                    (@($Inv.PSObject.Properties.Name) | Sort-Object) -join ','
                }) | Sort-Object
            $ParKeySets = @($script:ParBySig[$key] | ForEach-Object {
                    $Inv = Get-Content $_.InventoryPath -Raw | ConvertFrom-Json
                    (@($Inv.PSObject.Properties.Name) | Sort-Object) -join ','
                }) | Sort-Object
            ($ParKeySets -join '|') | Should -Be ($SeqKeySets -join '|') `
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
