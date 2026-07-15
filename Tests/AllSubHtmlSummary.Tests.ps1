# New-RdaAllSubHtmlSummary unit tests
# =============================================================================
# Offline, self-contained tests for the aggregate all-subscriptions HTML summary
# (New-RdaAllSubHtmlSummary in Functions/AllSubHtmlSummary.Functions.ps1). They
# build a synthetic set of per-subscription report folders (each a
# ResourcesReport<id>/ with a loose Inventory_*.json and a stub .html) in a temp
# dir, invoke the builder against them, and assert on the produced HTML: run
# totals equal the sum of fixtures, one row per subscription, self-containment
# (no external CDN refs), obfuscation posture detection, health banners,
# -Detailed charts, -SinceTime scoping, and fail-soft behaviour on an unreadable
# inventory.
#
# No live Azure and no literal GUIDs of any kind: obfuscated fixtures mint
# prod_/nonprod_ tokens at runtime with [guid]::NewGuid(), so no real (or
# hard-coded) GUID lives in this file.
# =============================================================================

BeforeAll {
    # Dot-source the function library under test so New-RdaAllSubHtmlSummary (and
    # its render helpers) load into the test scope.
    $FunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/AllSubHtmlSummary.Functions.ps1'
    if (-not (Test-Path $FunctionsFile)) { throw "AllSubHtmlSummary.Functions.ps1 not found at $FunctionsFile" }
    . $FunctionsFile

    $script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('AllSubHtmlSummaryTest_' + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null

    # Build one synthetic per-subscription report folder.
    #   -Services : hashtable of serviceName -> record count
    #   -SubName  : the Subscription value stamped on every record
    #   -Obfuscated : use prod_ GUID tokens for record Name + Subscription
    #   -NoHtml   : omit the sibling .html (to exercise the "no report" link)
    #   -BadInventory : write non-JSON so the fail-soft path is exercised
    function New-SubFolder
    {
        param(
            [Parameter(Mandatory)][string]$Root,
            [hashtable]$Services = @{},
            [string]$SubName = 'Contoso Prod',
            [switch]$Obfuscated,
            [switch]$NoHtml,
            [switch]$BadInventory
        )
        $Id = [guid]::NewGuid().ToString('N').Substring(0, 12)
        $Dir = Join-Path $Root ("ResourcesReport$Id")
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null

        if ($BadInventory)
        {
            'this is not valid json {{{' | Out-File -FilePath (Join-Path $Dir "Inventory_$Id.json") -Encoding utf8
        }
        else
        {
            $EffSubName = if ($Obfuscated) { 'prod_' + [guid]::NewGuid().ToString() } else { $SubName }
            $Inv = [ordered]@{ Version = '3.2.3' }
            foreach ($Svc in $Services.Keys)
            {
                $Recs = @()
                for ($i = 0; $i -lt $Services[$Svc]; $i++)
                {
                    $RecName = if ($Obfuscated) { 'prod_' + [guid]::NewGuid().ToString() } else { "$Svc-$i" }
                    $Recs += [ordered]@{ Name = $RecName; Subscription = $EffSubName; Location = 'eastus'; ResourceGroup = 'rg-app' }
                }
                $Inv[$Svc] = $Recs
            }
            ($Inv | ConvertTo-Json -Depth 10) | Out-File -FilePath (Join-Path $Dir "Inventory_$Id.json") -Encoding utf8
        }

        if (-not $NoHtml)
        {
            '<!DOCTYPE html><html><body>stub per-sub report</body></html>' | Out-File -FilePath (Join-Path $Dir "ResourcesReport_$Id.html") -Encoding utf8
        }
        return $Dir
    }

    function New-Run { $d = Join-Path $script:TmpRoot ('run_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $d -Force | Out-Null; $d }
    function Get-Card { param($Html, $Label) ([regex]::Match($Html, ('<div class="n">([0-9,]+)</div><div class="l">' + [regex]::Escape($Label)))).Groups[1].Value }
}

AfterAll {
    if ($script:TmpRoot -and (Test-Path $script:TmpRoot)) { Remove-Item -Path $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'New-RdaAllSubHtmlSummary aggregate report' {

    It 'produces a self-contained HTML whose totals equal the sum of the fixtures' {
        $Run = New-Run
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 2; StorageAcc = 1 } -SubName 'Sub A' | Out-Null
        New-SubFolder -Root $Run -Services @{ AppServices = 2 } -SubName 'Sub B' | Out-Null
        $Out = Join-Path $Run 'main.html'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out | Out-Null
        $Html = Get-Content -Path $Out -Raw

        Test-Path -Path $Out | Should -BeTrue
        (Get-Card $Html 'Total resources') | Should -Be '5' -Because '2+1+2 across the two fixtures'
        (Get-Card $Html 'Subscriptions') | Should -Be '2'
        # Self-contained: no external CDN/js/css references.
        ($Html -match '(?i)src="https?://' -or $Html -match '(?i)href="https?://' -or $Html -match '(?i)cdn|googleapis|jsdelivr') | Should -BeFalse
        # No <script> at all (pure static HTML).
        ($Html -match '<script') | Should -BeFalse
    }

    It 'renders exactly one table row per subscription plus the header row' {
        $Run = New-Run
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 1 } -SubName 'Sub A' | Out-Null
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 1 } -SubName 'Sub B' | Out-Null
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 1 } -SubName 'Sub C' | Out-Null
        $Out = Join-Path $Run 'main.html'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out | Out-Null
        $Html = Get-Content -Path $Out -Raw
        ([regex]::Matches($Html, '<tr>')).Count | Should -Be 4 -Because '3 subscription rows + 1 header row'
    }

    It 'counts an empty subscription and surfaces -FailedSubscriptions in the totals + banner' {
        $Run = New-Run
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 3 } -SubName 'Sub A' | Out-Null
        New-SubFolder -Root $Run -Services @{} -SubName 'Empty Sub' | Out-Null
        $Out = Join-Path $Run 'main.html'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out -FailedSubscriptions @('BrokenSub1', 'BrokenSub2') | Out-Null
        $Html = Get-Content -Path $Out -Raw
        (Get-Card $Html 'Empty (0 resources)') | Should -Be '1'
        (Get-Card $Html 'Failed') | Should -Be '2'
        $Html | Should -Match 'failed to process'
        $Html | Should -Match 'returned 0 resources'
    }

    It 'detects obfuscated posture from prod_/nonprod_ tokens' {
        $Run = New-Run
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 3; StorageAcc = 2 } -Obfuscated | Out-Null
        $Out = Join-Path $Run 'main.html'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out | Out-Null
        $Html = Get-Content -Path $Out -Raw
        $Html | Should -Match 'privacy-banner obfuscated'
        $Html | Should -Not -Match 'privacy-banner identifiable'
    }

    It 'defaults to identifiable posture for real names' {
        $Run = New-Run
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 3 } -SubName 'Contoso Production' | Out-Null
        $Out = Join-Path $Run 'main.html'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out | Out-Null
        $Html = Get-Content -Path $Out -Raw
        $Html | Should -Match 'privacy-banner identifiable'
    }

    It 'renders run-wide charts only when -Detailed is passed' {
        $Run = New-Run
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 2; StorageAcc = 1; AppServices = 1 } -SubName 'Sub A' | Out-Null

        $OutPlain = Join-Path $Run 'plain.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $OutPlain | Out-Null
        ((Get-Content $OutPlain -Raw) -match '<svg') | Should -BeFalse -Because 'Tier 1 (default) renders no charts'

        $OutDetailed = Join-Path $Run 'detailed.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $OutDetailed -Detailed | Out-Null
        ([regex]::Matches((Get-Content $OutDetailed -Raw), '<svg')).Count | Should -Be 2 -Because 'donut + bar'
    }

    It 'is fail-soft: an unreadable inventory does not abort the summary' {
        $Run = New-Run
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 4 } -SubName 'Good Sub' | Out-Null
        New-SubFolder -Root $Run -BadInventory | Out-Null
        $Out = Join-Path $Run 'main.html'

        { New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out } | Should -Not -Throw
        $Html = Get-Content -Path $Out -Raw
        (Get-Card $Html 'Total resources') | Should -Be '4' -Because 'the good sub still counts; the bad one is skipped'
        $Html | Should -Match 'unreadable inventory'
    }

    It 'scopes to -SinceTime, excluding older report folders' {
        $Run = New-Run
        $OldDir = New-SubFolder -Root $Run -Services @{ VirtualMachines = 9 } -SubName 'Old Sub'
        # Backdate the old folder well before the cutoff.
        (Get-Item $OldDir).LastWriteTime = (Get-Date).AddDays(-2)
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 2 } -SubName 'New Sub' | Out-Null
        $Out = Join-Path $Run 'main.html'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out -SinceTime (Get-Date).AddHours(-1) | Out-Null
        $Html = Get-Content -Path $Out -Raw
        (Get-Card $Html 'Total resources') | Should -Be '2' -Because 'only the recent folder is in scope'
        (Get-Card $Html 'Subscriptions') | Should -Be '1'
    }
}
