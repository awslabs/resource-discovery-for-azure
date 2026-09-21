# Validates the HTML report structure (service <details> sections keyed by id="svc-<slug>") and that every
# inventory resource type with data gets a section. Column-level schema lives in the JSON-driven tests.

BeforeAll {
    # Shared fixture builder. Defined in a file-level BeforeAll (so Pester v5 makes it
    # available at run time to every Describe's own BeforeAll) rather than inline in one
    # Describe. Both Describes call it to populate the same $script: state — the 'HTML
    # section invariants' Describe must not silently skip (fail-open) just because it ran
    # in isolation, was reordered, or a sibling's BeforeAll threw. One owner for the setup.
    function script:Initialize-ReportSchemaFixture
    {
        # Idempotent: if a sibling Describe already extracted this run's zip, reuse it.
        if ($script:ExtractPath -and (Test-Path $script:ExtractPath)) { return }

        $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
        {
            Get-ChildItem -Path $PSScriptRoot -Filter 'ResourcesReport_*.zip' |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1 -ExpandProperty FullName
        }

        if ([string]::IsNullOrEmpty($ZipPath) -or -not (Test-Path $ZipPath))
        {
            throw "No test zip found. Copy a ResourcesReport_*.zip to Tests/ or set `$env:TEST_ZIP_PATH"
        }

        $script:ExtractPath = Join-Path ([System.IO.Path]::GetTempPath()) "ReportSchemaTest_$([guid]::NewGuid().ToString().Substring(0,8))"
        New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
        Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

        $script:HtmlFile = Get-ChildItem -Path $script:ExtractPath -Filter '*.html' | Select-Object -First 1
        $script:HtmlContent = if ($script:HtmlFile) { Get-Content $script:HtmlFile.FullName -Raw } else { '' }

        # Extract the service-section slugs the report emitted. Summary.ps1
        # builds one <details class="service-section" id="svc-<slug>"> per
        # populated service, where <slug> is the service/JSON key lowercased
        # with non-alphanumerics replaced by '-'.
        $script:SectionSlugs = @()
        if ($script:HtmlContent)
        {
            $SvcMatches = [regex]::Matches($script:HtmlContent, 'id="svc-([a-z0-9-]+)"')
            $script:SectionSlugs = @($SvcMatches | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
        }

        $InvFile = Get-ChildItem -Path $script:ExtractPath -Filter 'Inventory_*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
        $script:InventoryJson = if ($InvFile) { Get-Content $InvFile.FullName -Raw | ConvertFrom-Json } else { $null }

        $script:ObfuscationSectionPattern = '^(prod|nonprod)-(databricks-|aks-|vmss-)?[0-9a-f]{8}-'
    }

    # Helper mirroring Summary.ps1's slug rule so tests can map a service
    # name to its expected section id.
    function script:Get-ServiceSlug([string]$Name)
    {
        return ($Name -replace '[^a-zA-Z0-9]', '-').ToLowerInvariant()
    }
}

Describe 'Report Schema Validation' {
    BeforeAll {
        script:Initialize-ReportSchemaFixture
    }

    AfterAll {
        if ($script:ExtractPath -and (Test-Path $script:ExtractPath))
        {
            Remove-Item -Path $script:ExtractPath -Recurse -Force
        }
    }

    It 'Should contain an HTML report file in the zip' {
        $script:HtmlFile | Should -Not -BeNullOrEmpty
    }

    It 'HTML report should be a self-contained document (no external CDN/script/style references)' {
        if (-not $script:HtmlContent) { Set-ItResult -Skipped -Because 'no HTML in fixture'; return }
        $script:HtmlContent | Should -Match '<!DOCTYPE html>' -Because 'the report must be a complete HTML document'
        # No external resource references - the report must render offline.
        $script:HtmlContent | Should -Not -Match 'src\s*=\s*["'']?(https?:)?//' -Because 'no external script/image sources allowed (any quoting, incl. protocol-relative)'
        $script:HtmlContent | Should -Not -Match '<link[^>]+href\s*=\s*["'']?(https?:)?//' -Because 'no external stylesheet links allowed (any quoting, incl. protocol-relative)'
        $script:HtmlContent | Should -Not -Match 'url\(\s*["'']?(https?:)?//' -Because 'no external CSS url() references (e.g. web fonts) allowed'
        $script:HtmlContent | Should -Not -Match '@import\s+["''](https?:)?//' -Because 'no external CSS @import references allowed'
    }

    It 'HTML report should not reference Excel/EPPlus artifacts' {
        if (-not $script:HtmlContent) { Set-ItResult -Skipped -Because 'no HTML in fixture'; return }
        $script:HtmlContent | Should -Not -Match 'OfficeOpenXml' -Because 'the HTML report has no Excel dependency'
    }

    It 'HTML report should declare a Total Resources figure' {
        if (-not $script:HtmlContent) { Set-ItResult -Skipped -Because 'no HTML in fixture'; return }
        $script:HtmlContent | Should -Match 'Total Resources[^0-9]*[0-9]' -Because 'the header summarises the run with a numeric total'
    }
}

# ============================================================
# Section / inventory parity. Every inventory JSON resource type with data
# should surface as a service section in the HTML report. This replaces the
# old "every populated worksheet exists" invariant.
# ============================================================
Describe 'HTML section invariants' {
    BeforeAll {
        # Populate the fixture from THIS Describe too, so the parity check cannot
        # fail-open (silently skip) when run in isolation, reordered, or after the
        # first Describe's BeforeAll threw. Idempotent: reuses an existing extract.
        script:Initialize-ReportSchemaFixture

        # "Fixture present" depends only on having an HTML report + inventory to
        # compare - NOT on the section count. If we folded SectionSlugs.Count
        # into this gate, a regression where Summary.ps1 emits an HTML with zero
        # sections (while the inventory has data) would SKIP the parity test
        # instead of failing it. We want that case to fail loudly.
        $script:FixtureReady = [bool]$script:HtmlFile -and -not [string]::IsNullOrWhiteSpace($script:HtmlContent)
    }

    It 'Every inventory resource type with data should have a corresponding HTML section' {
        if (-not $script:FixtureReady -or $null -eq $script:InventoryJson)
        {
            Set-ItResult -Skipped -Because 'no HTML or inventory JSON in fixture'
            return
        }
        $script:InventoryJson.PSObject.Properties |
            Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' -and @($_.Value).Count -gt 0 } |
            ForEach-Object {
                $ExpectedSlug = script:Get-ServiceSlug $_.Name
                $script:SectionSlugs | Should -Contain $ExpectedSlug `
                    -Because "inventory key '$($_.Name)' has resources but HTML section 'svc-$ExpectedSlug' is missing"
            }
    }

    It 'No HTML section id should itself be obfuscated' {
        # The obfuscator runs on resource VALUES, never on service/type names.
        # A section slug is derived from the service key (e.g. "VirtualMachines"
        # -> "virtualmachines"), so it must never look like an obfuscated token.
        if (-not $script:FixtureReady) { Set-ItResult -Skipped -Because 'no fixture'; return }
        foreach ($slug in $script:SectionSlugs)
        {
            $slug | Should -Not -Match $script:ObfuscationSectionPattern -Because "section slug '$slug' looks obfuscated; service names must remain literal"
        }
    }

    It 'Report should contain at least one populated service section' {
        # Fail (not skip) when an HTML fixture exists with a populated inventory
        # but rendered zero sections - that is the regression this guards.
        if (-not $script:FixtureReady -or $null -eq $script:InventoryJson) { Set-ItResult -Skipped -Because 'no fixture'; return }
        $PopulatedCount = @($script:InventoryJson.PSObject.Properties |
                Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' -and @($_.Value).Count -gt 0 }).Count
        if ($PopulatedCount -eq 0) { Set-ItResult -Skipped -Because 'inventory has no populated resource types'; return }
        $script:SectionSlugs.Count | Should -BeGreaterThan 0 -Because 'a populated inventory must render at least one service section'
    }

    AfterAll {
        # Clean up when this Describe created/owns the extract (e.g. run in isolation).
        if ($script:ExtractPath -and (Test-Path $script:ExtractPath))
        {
            Remove-Item -Path $script:ExtractPath -Recurse -Force
        }
    }
}
