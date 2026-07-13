# Report Schema Validation Tests
# Validates that the HTML report is present and structurally correct, and that
# every inventory resource type with data surfaces as a section in the report.
#
# The report format changed from Excel (.xlsx worksheets) to a self-contained
# HTML file produced by Extension/Summary.ps1. These tests therefore validate
# the HTML structure (service <details> sections keyed by id="svc-<slug>")
# instead of worksheet names/columns. Column-level schema correctness is now
# covered by the inventory-JSON-driven tests (the JSON is the source the HTML
# renders from).
#
# Run with: Invoke-Pester ./Tests/ReportSchema.Tests.ps1 -Output Detailed

Describe 'Report Schema Validation' {
    BeforeAll {
        $zipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
        {
            Get-ChildItem -Path $PSScriptRoot -Filter 'ResourcesReport_*.zip' |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1 -ExpandProperty FullName
        }

        if ([string]::IsNullOrEmpty($zipPath) -or -not (Test-Path $zipPath))
        {
            throw "No test zip found. Copy a ResourcesReport_*.zip to Tests/ or set `$env:TEST_ZIP_PATH"
        }

        $script:ExtractPath = Join-Path ([System.IO.Path]::GetTempPath()) "ReportSchemaTest_$([guid]::NewGuid().ToString().Substring(0,8))"
        New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $script:ExtractPath -Force

        $script:HtmlFile = Get-ChildItem -Path $script:ExtractPath -Filter '*.html' | Select-Object -First 1
        $script:HtmlContent = if ($script:HtmlFile) { Get-Content $script:HtmlFile.FullName -Raw } else { '' }

        # Extract the service-section slugs the report emitted. Summary.ps1
        # builds one <details class="service-section" id="svc-<slug>"> per
        # populated service, where <slug> is the service/JSON key lowercased
        # with non-alphanumerics replaced by '-'.
        $script:SectionSlugs = @()
        if ($script:HtmlContent)
        {
            $svcMatches = [regex]::Matches($script:HtmlContent, 'id="svc-([a-z0-9-]+)"')
            $script:SectionSlugs = @($svcMatches | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
        }

        # Helper mirroring Summary.ps1's slug rule so tests can map a service
        # name to its expected section id.
        function script:Get-ServiceSlug([string]$Name)
        {
            return ($Name -replace '[^a-zA-Z0-9]', '-').ToLower()
        }

        $invFile = Get-ChildItem -Path $script:ExtractPath -Filter 'Inventory_*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
        $script:InventoryJson = if ($invFile) { Get-Content $invFile.FullName -Raw | ConvertFrom-Json } else { $null }

        $script:ObfuscationSectionPattern = '^(prod|nonprod)-(databricks-|aks-|vmss-)?[0-9a-f]{8}-'
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
        $script:HtmlContent | Should -Not -Match 'src\s*=\s*"https?://' -Because 'no external script/image sources allowed'
        $script:HtmlContent | Should -Not -Match '<link[^>]+href\s*=\s*"https?://' -Because 'no external stylesheet links allowed'
    }

    It 'HTML report should not reference Excel/EPPlus artifacts' {
        if (-not $script:HtmlContent) { Set-ItResult -Skipped -Because 'no HTML in fixture'; return }
        $script:HtmlContent | Should -Not -Match 'OfficeOpenXml' -Because 'the HTML report has no Excel dependency'
    }

    It 'HTML report should declare a Total Resources figure' {
        if (-not $script:HtmlContent) { Set-ItResult -Skipped -Because 'no HTML in fixture'; return }
        $script:HtmlContent | Should -Match 'Total Resources' -Because 'the header summarises the run'
    }
}

# ============================================================
# Section / inventory parity. Every inventory JSON resource type with data
# should surface as a service section in the HTML report. This replaces the
# old "every populated worksheet exists" invariant.
# ============================================================
Describe 'HTML section invariants' {
    BeforeAll {
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
                $expectedSlug = script:Get-ServiceSlug $_.Name
                $script:SectionSlugs | Should -Contain $expectedSlug `
                    -Because "inventory key '$($_.Name)' has resources but HTML section 'svc-$expectedSlug' is missing"
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
        $populatedCount = @($script:InventoryJson.PSObject.Properties |
                Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' -and @($_.Value).Count -gt 0 }).Count
        if ($populatedCount -eq 0) { Set-ItResult -Skipped -Because 'inventory has no populated resource types'; return }
        $script:SectionSlugs.Count | Should -BeGreaterThan 0 -Because 'a populated inventory must render at least one service section'
    }
}
