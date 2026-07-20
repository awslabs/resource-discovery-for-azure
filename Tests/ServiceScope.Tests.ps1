# Service Scope Tests
# =============================================================================
# Validates that a -Service-scoped run produced an inventory containing ONLY the
# requested service collectors (plus non-service metadata like Version). This is
# the output-level proof of the -Service filter on ResourceInventory.ps1 and the
# Run-AllSubscriptions.ps1 wrapper: whatever services were requested, NO other
# resource type may appear in the inventory.
#
# Driven by environment variables (same pattern as the other suites):
#   $env:TEST_ZIP_PATH          - the output zip to validate (required)
#   $env:TEST_EXPECTED_SERVICES - comma-separated collector base names that were
#                                 requested via -Service (e.g. "VirtualMachines,Streamanalytics")
#
# When either is unset the whole suite is marked Skipped, so it is inert for the
# other scenarios / standalone runs and only asserts when the scenario matrix
# (or an operator) points it at a scoped zip.
#
# Run with (point TEST_ZIP_PATH at ONE concrete zip, not a wildcard):
#   $env:TEST_ZIP_PATH = '/path/to/ResourcesReport_<timestamp>.zip'
#   $env:TEST_EXPECTED_SERVICES = 'VirtualMachines'
#   Invoke-Pester ./Tests/ServiceScope.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    # Non-service top-level keys that are always allowed regardless of -Service.
    # 'Version' is the inventory metadata stamp the other suites exclude by name
    # (e.g. DictionaryValidation / ProdNonprodPrefix use `$_.Name -ne 'Version'`).
    $script:MetadataKeys = @('Version')

    $ZipPath = $env:TEST_ZIP_PATH
    $script:Expected = @()
    if (-not [string]::IsNullOrEmpty($env:TEST_EXPECTED_SERVICES))
    {
        $script:Expected = @($env:TEST_EXPECTED_SERVICES -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $script:Active = (-not [string]::IsNullOrEmpty($ZipPath)) -and (Test-Path $ZipPath) -and ($script:Expected.Count -gt 0)

    $script:Inventory = $null
    if ($script:Active)
    {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $script:ExtractPath = Join-Path $TmpBase ("ServiceScopeTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
        Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

        $InvFile = Get-ChildItem -Path $script:ExtractPath -Filter 'Inventory_*.json' | Select-Object -First 1
        if ($InvFile) { $script:Inventory = Get-Content $InvFile.FullName -Raw | ConvertFrom-Json }
    }
}

AfterAll {
    if ($script:ExtractPath -and (Test-Path $script:ExtractPath)) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe 'Service Scope' {
    It 'inventory contains ONLY the requested service collectors (plus metadata)' {
        if (-not $script:Active) { Set-ItResult -Skipped -Because 'TEST_ZIP_PATH / TEST_EXPECTED_SERVICES not set'; return }
        $script:Inventory | Should -Not -BeNullOrEmpty -Because 'the scoped run must still produce an inventory'

        $Allowed = @($script:Expected + $script:MetadataKeys)
        $Keys = @($script:Inventory.PSObject.Properties.Name)
        $Unexpected = @($Keys | Where-Object { $_ -notin $Allowed })
        $Unexpected | Should -BeNullOrEmpty -Because ("only [{0}] (+ metadata) should be present; found disallowed key(s) [{1}]" -f ($script:Expected -join ', '), ($Unexpected -join ', '))
    }

    It 'does not emit any service key outside the requested set' {
        if (-not $script:Active) { Set-ItResult -Skipped -Because 'TEST_ZIP_PATH / TEST_EXPECTED_SERVICES not set'; return }
        # Redundant-but-explicit: every populated top-level service key (excluding
        # metadata) must be one that was requested. Guards against a collector
        # leaking output when it was not in -Service.
        $Keys = @($script:Inventory.PSObject.Properties.Name | Where-Object { $_ -notin $script:MetadataKeys })
        foreach ($k in $Keys)
        {
            $k | Should -BeIn $script:Expected -Because "service key '$k' was not in the requested -Service set [$($script:Expected -join ', ')]"
        }
    }
}
