#Requires -Version 7.0
<#
    Reproduction + regression coverage for the report-stamp collision
    (fable review finding C1).

    The producer (ResourceInventory.ps1) builds a report stamp as
    yyyyMMddHHmmssfff (17 digits) + a 4-char hex per-process discriminator, so two
    parallel workers that hit the same millisecond emit names that differ ONLY in
    the hex tail, e.g. ResourcesReport_20260101000000000ab1f.zip vs
    ResourcesReport_20260101000000000c02e.zip.

    Get-RdaReportId keys on '(\d{15,})', which captures only the leading digit run
    and therefore returns the SAME key for both. Get-RdaInventorySource then groups
    on that key and keeps one member per group, dropping the other WITHOUT recording
    it in Missing/Unreadable/Rejected/Skipped - a silent loss of one subscription.

    All fixture data is invented. No real subscription, tenant, resource or
    customer identifier appears anywhere in this file.
#>

BeforeAll {
    $Script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $Script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $Script:RepoRoot 'Functions/FindResource.Functions.ps1')

    # Two same-millisecond stamps that differ only in the 4-char hex discriminator.
    $Script:StampMillis = '20260101000000000'   # 17 digits
    $Script:NameA = "ResourcesReport_${StampMillis}ab1f.zip"
    $Script:NameB = "ResourcesReport_${StampMillis}c02e.zip"

    $Script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("RdaStampCollision_{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $Script:TestRoot -Force | Out-Null

    # Discovery classifies PerSubZip by NAME and does not open the archive, so an
    # empty file under each name is a sufficient, valid two-source fixture.
    New-Item -ItemType File -Path (Join-Path $Script:TestRoot $Script:NameA) -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $Script:TestRoot $Script:NameB) -Force | Out-Null
}

AfterAll {
    if ($Script:TestRoot -and (Test-Path -LiteralPath $Script:TestRoot)) {
        Remove-Item -LiteralPath $Script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'C1: report-stamp collision on same-millisecond reports' {

    It 'Get-RdaReportId must give DIFFERENT keys to two reports that differ only in the hex discriminator' {
        $IdA = Get-RdaReportId -Name $Script:NameA
        $IdB = Get-RdaReportId -Name $Script:NameB
        # These are two distinct subscriptions' reports; their keys must differ.
        $IdA | Should -Not -Be $IdB
    }

    It 'Get-RdaInventorySource must not silently drop the colliding second report' {
        $Result = Get-RdaInventorySource -Path $Script:TestRoot

        $SourceFiles = @($Result.Sources | ForEach-Object { [System.IO.Path]::GetFileName($_.File) })
        $AccountedElsewhere = @($Result.Missing) + @($Result.Unreadable) + @($Result.Rejected) + @($Result.Skipped)

        # Both reports must be reachable: either both survive as sources, or a
        # dropped one is explicitly recorded somewhere. Neither may vanish.
        foreach ($Name in @($Script:NameA, $Script:NameB)) {
            $InSources = $SourceFiles -contains $Name
            $Recorded = @($AccountedElsewhere | Where-Object { $_ -like "*$Name*" }).Count -gt 0
            ($InSources -or $Recorded) | Should -BeTrue -Because "$Name must not disappear without a trace"
        }
    }
}
