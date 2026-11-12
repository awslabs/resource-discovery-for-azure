# New-RdaAllSubHtmlSummary writes the main summary by its literal path: a run
# folder or a file name may hold [ or ], which -FilePath reads as a wildcard
# (no file, or a file of another name).
#
# Offline; generic names only.
#
# Run with: Invoke-Pester ./Tests/MainSummaryLiteralPath.Tests.ps1 -Output Detailed

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/AllSubHtmlSummary.Functions.ps1')
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('MainSummaryLiteralPath_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
}

AfterAll {
    if ($script:TestBase -and (Test-Path -LiteralPath $script:TestBase)) { Remove-Item -LiteralPath $script:TestBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'The main summary written by its literal path' {
    It 'is written as <Name> in a run folder named <Folder>' -ForEach @(
        @{ Folder = 'run[1]'; Name = 'MainSummary.html' }
        @{ Folder = 'run1'; Name = 'main[1].html' }
    ) {
        $Run = Join-Path $script:TestBase $Folder
        $Report = Join-Path $Run 'ResourcesReport_20260102030405001'
        $null = New-Item -ItemType Directory -Path $Report -Force
        Set-Content -LiteralPath (Join-Path $Report 'Inventory_ResourcesReport_20260102030405001.json') -Value '{"Version":"3.2.3","PublicIP":[{"Name":"pip","Subscription":"Sub"}]}'
        Set-Content -LiteralPath (Join-Path $Report 'ResourcesReport_20260102030405001.html') -Value '<html></html>'
        # A file a wildcard read of the name would also match.
        Set-Content -LiteralPath (Join-Path $Run 'main1.html') -Value 'not the summary' -NoNewline
        $Html = Join-Path $Run $Name
        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Html 6>$null | Out-Null
        Test-Path -LiteralPath $Html -PathType Leaf | Should -BeTrue
        Get-Content -LiteralPath $Html -Raw | Should -Match '<html'
        Get-Content -LiteralPath (Join-Path $Run 'main1.html') -Raw | Should -Be 'not the summary'
    }
}
