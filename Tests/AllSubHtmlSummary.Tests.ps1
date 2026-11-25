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
# No live Azure and no real GUIDs: obfuscated fixtures mint prod_/nonprod_
# tokens at runtime with [guid]::NewGuid(). The only literal GUID in this file
# is the Azure documentation placeholder (12345678-1234-1234-1234-123456789012),
# used by the obfuscation-redaction tests to prove a passed-in tenant id is
# suppressed under -Obfuscated.
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
            [switch]$BadInventory,
            [switch]$WithTags
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
                    $Rec = [ordered]@{ Name = $RecName; Subscription = $EffSubName; Location = 'eastus'; ResourceGroup = 'rg-app' }
                    if ($WithTags)
                    {
                        # Tag shape as it appears in a real Inventory json: an array
                        # of { Name; Value } objects (the thing that used to render
                        # as "(obj)").
                        $Rec['Tags'] = @(
                            [ordered]@{ Name = 'env'; Value = 'prod' },
                            [ordered]@{ Name = 'owner'; Value = 'team-a' }
                        )
                    }
                    $Recs += $Rec
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

    function New-Run { $Dir = Join-Path $script:TmpRoot ('run_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $Dir -Force | Out-Null; $Dir }
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

Describe 'New-RdaAllSubHtmlSummaryFromZip (rebuild from consolidated zip)' {

    BeforeAll {
        # Build a synthetic consolidated outer zip that mirrors the real layout:
        # an outer zip whose members are per-subscription ResourcesReport*.zip
        # files, each of which contains that sub's loose Inventory_*.json + .html
        # at the archive root (flat) - exactly what a customer bundle looks like.
        function New-ConsolidatedZip
        {
            param([Parameter(Mandatory)][string]$Root, [switch]$WithTags)
            $SrcDir = Join-Path $Root ('src_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            $InnerDir = Join-Path $Root ('inner_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            New-Item -ItemType Directory -Path $SrcDir, $InnerDir -Force | Out-Null

            $F1 = New-SubFolder -Root $SrcDir -Services @{ VirtualMachines = 2; StorageAcc = 1 } -SubName 'Sub A' -WithTags:$WithTags
            $F2 = New-SubFolder -Root $SrcDir -Services @{ AppServices = 3 } -SubName 'Sub B' -WithTags:$WithTags
            foreach ($F in @($F1, $F2))
            {
                $Base = Split-Path $F -Leaf                       # ResourcesReport<id>
                $InnerZip = Join-Path $InnerDir ($Base + '.zip')  # ResourcesReport<id>.zip
                # Flat entries at the archive root, matching the real per-sub zip.
                Compress-Archive -Path (Join-Path $F '*') -DestinationPath $InnerZip -Force
            }
            $Outer = Join-Path $Root ('AllSubscriptions_ResourcesReport_test_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.zip')
            Compress-Archive -Path (Join-Path $InnerDir '*') -DestinationPath $Outer -Force
            return $Outer
        }
    }

    It 'reconstructs per-sub folders and builds a summary whose link targets exist' {
        $Run = New-Run
        $Outer = New-ConsolidatedZip -Root $Run
        $OutDir = Join-Path $Run 'rebuilt'

        $Html = New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer -OutputDirectory $OutDir
        Test-Path -Path $Html | Should -BeTrue
        $Content = Get-Content -Path $Html -Raw
        (Get-Card $Content 'Total resources') | Should -Be '6' -Because '2+1+3 across the two subs'
        (Get-Card $Content 'Subscriptions') | Should -Be '2'

        # Every per-sub folder was reconstructed with its .html (the link target).
        $SubFolders = @(Get-ChildItem -Path $OutDir -Directory -Filter 'ResourcesReport*')
        $SubFolders.Count | Should -Be 2
        foreach ($Sf in $SubFolders)
        {
            @(Get-ChildItem -Path $Sf.FullName -Filter '*.html' -File).Count | Should -BeGreaterThan 0
        }

        # Each href in the table resolves to a real file under the output dir.
        $Links = [regex]::Matches($Content, 'href="([^"]+\.html)"') | ForEach-Object { $_.Groups[1].Value }
        $Links.Count | Should -Be 2
        foreach ($L in $Links)
        {
            Test-Path -Path (Join-Path $OutDir $L) | Should -BeTrue -Because "link '$L' must resolve on disk"
        }
    }

    It 'emits a portable bundle with -PackageZip' {
        $Run = New-Run
        $Outer = New-ConsolidatedZip -Root $Run
        $OutDir = Join-Path $Run 'rebuilt_pkg'

        New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer -OutputDirectory $OutDir -PackageZip | Out-Null
        Test-Path -Path ($OutDir + '.zip') | Should -BeTrue -Because '-PackageZip zips the reconstructed folder'
    }

    It 'rebuilt summary: every Folder link resolves after the -PackageZip bundle is unzipped to a fresh folder' {
        $Run = New-Run
        $Outer = New-ConsolidatedZip -Root $Run
        $OutDir = Join-Path $Run 'rebuilt_folder'
        New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer -OutputDirectory $OutDir -PackageZip | Out-Null

        $Fresh = Join-Path $Run ('fresh_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        Expand-Archive -LiteralPath ($OutDir + '.zip') -DestinationPath $Fresh
        $Html = Get-Content -LiteralPath (Join-Path $Fresh 'MainSummary.html') -Raw
        $Links = @([regex]::Matches($Html, '<a class="folder" href="([^"]+)">') | ForEach-Object { $_.Groups[1].Value })
        $Links.Count | Should -Be 2
        foreach ($L in $Links)
        {
            Test-Path -LiteralPath (Join-Path $Fresh ([uri]::UnescapeDataString($L))) -PathType Container | Should -BeTrue -Because "Folder link '$L' must resolve after unzip"
        }
    }

    It 'throws on an archive that holds no per-subscription reports' {
        $Run = New-Run
        $Junk = Join-Path $Run 'junk.zip'
        'nothing useful' | Out-File -FilePath (Join-Path $Run 'readme.txt') -Encoding utf8
        Compress-Archive -Path (Join-Path $Run 'readme.txt') -DestinationPath $Junk -Force
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Junk -OutputDirectory (Join-Path $Run 'rebuilt_junk') } | Should -Throw
    }

    It 're-renders per-sub reports so Tags show key=value, not (obj)' {
        $Run = New-Run
        $Outer = New-ConsolidatedZip -Root $Run -WithTags
        $OutDir = Join-Path $Run 'rebuilt_tags'

        New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer -OutputDirectory $OutDir | Out-Null

        # A per-sub report (not the aggregate MainSummary) must now render tags
        # as key=value with no "(obj)" placeholder, proving the re-render used the
        # current Summary.ps1 rather than the stale html baked into the zip.
        $SubHtml = Get-ChildItem -Path $OutDir -Recurse -Filter '*.html' -File |
            Where-Object { $_.Name -notlike 'MainSummary*' } | Select-Object -First 1
        $SubHtml | Should -Not -BeNullOrEmpty
        $Content = Get-Content -Path $SubHtml.FullName -Raw
        $Content | Should -Not -Match '\(obj\)'
        $Content | Should -Match 'env=prod'
        # And it is a freshly rendered report, not the stub that was in the zip.
        $Content | Should -Not -Match 'stub per-sub report'
    }

    It 'keeps the original per-sub html verbatim with -KeepOriginalReports' {
        $Run = New-Run
        $Outer = New-ConsolidatedZip -Root $Run -WithTags
        $OutDir = Join-Path $Run 'rebuilt_keep'

        New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer -OutputDirectory $OutDir -KeepOriginalReports | Out-Null

        $SubHtml = Get-ChildItem -Path $OutDir -Recurse -Filter '*.html' -File |
            Where-Object { $_.Name -notlike 'MainSummary*' } | Select-Object -First 1
        (Get-Content -Path $SubHtml.FullName -Raw) | Should -Match 'stub per-sub report' -Because 'the original zip html is preserved, not re-rendered'
    }

    It 'excludes a leftover *_revealed.zip so no de-obfuscated report leaks into the reconstruction or the -PackageZip bundle' {
        # Regression for the PII leak vector: the reveal engine names only the OUTER
        # zip *_revealed.zip and rewrites the inner html/json members IN PLACE (their
        # names carry no _revealed marker). A member-name-only filter would let those
        # real-data members through; the guard must exclude at the zip/folder
        # SELECTION level. Build a consolidated zip that carries one legitimate
        # obfuscated inner report PLUS a leftover ResourcesReport_<id>_revealed.zip
        # whose members hold a real (identifiable) marker, then assert the marker
        # never reaches the reconstruction or the shareable bundle.
        $Run = New-Run
        $Marker = 'REAL-IDENTIFIER-DO-NOT-LEAK'
        $Stage = Join-Path $Run ('revsrc_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $InnerDir = Join-Path $Run ('revinner_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $Stage, $InnerDir -Force | Out-Null

        # Legitimate obfuscated per-sub report -> ResourcesReport<id>.zip
        $Good = New-SubFolder -Root $Stage -Services @{ VirtualMachines = 2 } -Obfuscated
        $GoodBase = Split-Path $Good -Leaf
        Compress-Archive -Path (Join-Path $Good '*') -DestinationPath (Join-Path $InnerDir ($GoodBase + '.zip')) -Force

        # Leftover de-obfuscated report: members keep their normal names (real data),
        # only the inner zip carries the _revealed suffix.
        $RevId = [guid]::NewGuid().ToString('N').Substring(0, 12)
        $RevSrc = Join-Path $Run ('rev_' + $RevId)
        New-Item -ItemType Directory -Path $RevSrc -Force | Out-Null
        ([ordered]@{ Version = '3.2.3'; VirtualMachines = @([ordered]@{ Name = $Marker; Subscription = $Marker; Location = 'eastus'; ResourceGroup = 'rg-app' }) } | ConvertTo-Json -Depth 10) |
            Out-File -FilePath (Join-Path $RevSrc "Inventory_$RevId.json") -Encoding utf8
        ('<!DOCTYPE html><html><body>' + $Marker + '</body></html>') | Out-File -FilePath (Join-Path $RevSrc "ResourcesReport_$RevId.html") -Encoding utf8
        Compress-Archive -Path (Join-Path $RevSrc '*') -DestinationPath (Join-Path $InnerDir ("ResourcesReport_${RevId}_revealed.zip")) -Force

        $Outer = Join-Path $Run ('AllSubscriptions_ResourcesReport_revtest_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.zip')
        Compress-Archive -Path (Join-Path $InnerDir '*') -DestinationPath $Outer -Force

        $OutDir = Join-Path $Run 'rebuilt_rev'
        New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer -OutputDirectory $OutDir -PackageZip | Out-Null

        # The legit obfuscated sub is still reconstructed; the revealed one is not.
        @(Get-ChildItem -Path $OutDir -Directory -Filter 'ResourcesReport*').Count | Should -Be 1
        @(Get-ChildItem -Path $OutDir -Recurse -Force | Where-Object { $_.Name -like '*_revealed*' }).Count |
            Should -Be 0 -Because 'no *_revealed* artefact may be reconstructed on disk'

        # The real identifier must appear nowhere in the reconstructed folder.
        @(Get-ChildItem -Path $OutDir -Recurse -File | Where-Object { (Get-Content -Path $_.FullName -Raw) -match [regex]::Escape($Marker) }).Count |
            Should -Be 0 -Because 'the de-obfuscated marker must not land in the reconstruction'

        # ...nor in the shareable -PackageZip bundle.
        $Bundle = $OutDir + '.zip'
        Test-Path -Path $Bundle | Should -BeTrue
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Bundle)
        try
        {
            @($Archive.Entries | Where-Object { $_.FullName -like '*_revealed*' }).Count |
                Should -Be 0 -Because 'the portable bundle must carry no *_revealed* entry'
        }
        finally { $Archive.Dispose() }
    }
}

Describe 'New-RdaAllSubHtmlSummary obfuscation redaction (shareable-bundle leak guard)' {

    It 'under -Obfuscated suppresses the tenant id and renders health banners counts-only (no subscription names)' {
        $Run = New-Run
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 2 } -Obfuscated | Out-Null
        $Out = Join-Path $Run 'main.html'
        # Azure documentation placeholder GUID (not a real tenant).
        $RealTenant = '12345678-1234-1234-1234-123456789012'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out -Obfuscated `
            -TenantId $RealTenant `
            -FailedSubscriptions @('Contoso-Prod-Sub') `
            -ConsumptionFailedSubs @([pscustomobject]@{ Name = 'Fabrikam-Billing'; Id = '12345678-1234-1234-1234-123456789012' }) `
            -MetricsFailedSubs @([pscustomobject]@{ Name = 'Northwind-Metrics'; Id = '12345678-1234-1234-1234-123456789012' }) | Out-Null
        $Html = Get-Content -Path $Out -Raw

        # No real identifiers reach the shareable summary.
        $Html | Should -Not -Match ([regex]::Escape($RealTenant))
        $Html | Should -Not -Match 'Tenant:'
        $Html | Should -Not -Match 'Contoso-Prod-Sub'
        $Html | Should -Not -Match 'Fabrikam-Billing'
        $Html | Should -Not -Match 'Northwind-Metrics'
        # But the banners (and their counts) still render so the operator sees the health signal.
        $Html | Should -Match 'failed to process'
        $Html | Should -Match 'consumption \(billing\) issues'
        $Html | Should -Match 'metrics issues'
    }

    It 'without -Obfuscated a non-obfuscated bundle still lists the affected subscription names' {
        $Run = New-Run
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 2 } -SubName 'Contoso Production' | Out-Null
        $Out = Join-Path $Run 'main.html'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out `
            -TenantId '12345678-1234-1234-1234-123456789012' `
            -ConsumptionFailedSubs @([pscustomobject]@{ Name = 'Fabrikam-Billing'; Id = '12345678-1234-1234-1234-123456789012' }) | Out-Null
        $Html = Get-Content -Path $Out -Raw

        $Html | Should -Match 'Tenant:' -Because 'an identifiable bundle shows the tenant'
        $Html | Should -Match 'Fabrikam-Billing' -Because 'an identifiable bundle names the affected subs'
    }
}

Describe 'MainSummary Folder link (each row links to its report folder)' {

    It 'gives every row a relative Folder link that resolves to its report folder' {
        $Run = New-Run
        $A = New-SubFolder -Root $Run -Services @{ VirtualMachines = 2 } -SubName 'Sub A'
        $B = New-SubFolder -Root $Run -Services @{ AppServices = 1 } -SubName 'Sub B' -NoHtml
        $Out = Join-Path $Run 'main.html'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out | Out-Null
        $Html = Get-Content -Path $Out -Raw

        $Html | Should -Match '<th>Folder</th>'
        $Links = @([regex]::Matches($Html, '<a class="folder" href="([^"]+)">') | ForEach-Object { $_.Groups[1].Value })
        $Links.Count | Should -Be 2 -Because 'one Folder link per row, also for a row with no per-sub html'
        ($Links | Sort-Object) | Should -Be (@(((Split-Path $A -Leaf) + '/'), ((Split-Path $B -Leaf) + '/')) | Sort-Object)
        foreach ($L in $Links)
        {
            $L | Should -Not -Match '^(/|[A-Za-z]:|\\\\)' -Because 'the link is relative, never an absolute local path'
            Test-Path -LiteralPath (Join-Path $Run ([uri]::UnescapeDataString($L))) -PathType Container | Should -BeTrue
        }
        $Html | Should -Not -Match ([regex]::Escape($Run)) -Because 'no local path leaks into the page'
    }

    It 'URL-encodes the folder name in the Folder link and in the Report link' {
        $Run = New-Run
        $Dir = New-SubFolder -Root $Run -Services @{ VirtualMachines = 1 } -SubName 'Sub A'
        $HtmlName = (Get-ChildItem -LiteralPath $Dir -Filter '*.html').Name
        $Odd = Join-Path $Run 'ResourcesReport a#b&c%d'
        Move-Item -LiteralPath $Dir -Destination $Odd
        $Out = Join-Path $Run 'main.html'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out | Out-Null
        $Html = Get-Content -Path $Out -Raw

        $Html | Should -Match ([regex]::Escape('<a class="folder" href="ResourcesReport%20a%23b%26c%25d/">'))
        $Html | Should -Match ([regex]::Escape(('<a href="ResourcesReport%20a%23b%26c%25d/{0}">' -f $HtmlName))) -Because 'the Report link is encoded and joined with / too, on every OS'
        foreach ($Href in @([regex]::Matches($Html, '<a (?:class="folder" )?href="([^"]+)">') | ForEach-Object { $_.Groups[1].Value }))
        {
            Test-Path -LiteralPath (Join-Path $Run ([uri]::UnescapeDataString($Href))) | Should -BeTrue -Because "link '$Href' must resolve"
        }
    }

    It 'still writes a summary a caller puts elsewhere to move it beside the folders later' {
        $Run = New-Run
        New-SubFolder -Root $Run -Services @{ VirtualMachines = 1 } -SubName 'Sub A' | Out-Null
        $Elsewhere = Join-Path $script:TmpRoot ('work_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Elsewhere -Force | Out-Null
        $Out = Join-Path $Elsewhere 'MainSummary.html'

        { New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out } | Should -Not -Throw
        Move-Item -LiteralPath $Out -Destination (Join-Path $Run 'MainSummary.html')
        $Html = Get-Content -LiteralPath (Join-Path $Run 'MainSummary.html') -Raw
        foreach ($Href in @([regex]::Matches($Html, '<a (?:class="folder" )?href="([^"]+)">') | ForEach-Object { $_.Groups[1].Value }))
        {
            Test-Path -LiteralPath (Join-Path $Run ([uri]::UnescapeDataString($Href))) | Should -BeTrue -Because "link '$Href' resolves once the page sits in the run folder"
        }
    }

    It 'under -Obfuscated the Folder link holds only the report stamp, no real name' {
        $Run = New-Run
        $A = New-SubFolder -Root $Run -Services @{ VirtualMachines = 2 } -Obfuscated
        $Out = Join-Path $Run 'main.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out -Obfuscated -FailedSubscriptions @('Contoso-Prod-Sub') | Out-Null
        $Html = Get-Content -Path $Out -Raw
        $Links = @([regex]::Matches($Html, '<a class="folder" href="([^"]+)">') | ForEach-Object { $_.Groups[1].Value })
        $Links | Should -Be @((Split-Path $A -Leaf) + '/')
        $Links[0] | Should -Match '^ResourcesReport_?[0-9a-f]+/$'
        $Html | Should -Not -Match 'Contoso-Prod-Sub'
    }

    It 'gives the unreadable-inventory row a Folder link too' {
        $Run = New-Run
        $Bad = New-SubFolder -Root $Run -BadInventory
        $Out = Join-Path $Run 'main.html'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out | Out-Null
        (Get-Content -Path $Out -Raw) | Should -Match ([regex]::Escape(('<a class="folder" href="{0}/">' -f (Split-Path $Bad -Leaf))))
    }

    It 'keeps the empty-table row spanning every column' {
        $Run = New-Run
        $Out = Join-Path $Run 'main.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out | Out-Null
        (Get-Content -Path $Out -Raw) | Should -Match '<td colspan="5" class="muted">No per-subscription reports'
    }

}

Describe 'ConvertTo-RdaBundleLink and Copy-RdaBundleSummary (consolidated zip copy of MainSummary)' {

    It 'keeps a Folder link whose folder is in the bundle and mutes one whose folder is not' {
        $Root = New-Run
        New-Item -ItemType Directory -Path (Join-Path $Root 'HTML_1') -Force | Out-Null
        $In = '<td><a class="folder" href="HTML_1/">folder &#8599;</a></td><td><a class="folder" href="HTML_2/">folder &#8599;</a></td>'

        $OutHtml = ConvertTo-RdaBundleLink -Html $In -BundleRoot $Root

        $OutHtml | Should -Be '<td><a class="folder" href="HTML_1/">folder &#8599;</a></td><td><span class="muted">no folder</span></td>'
    }

    It 'mutes a Folder link that would leave the bundle root' {
        $Root = New-Run
        New-Item -ItemType Directory -Path (Join-Path $Root 'HTML_1') -Force | Out-Null
        $In = '<a class="folder" href="../">folder &#8599;</a><a class="folder" href="HTML_1/../HTML_1/">folder &#8599;</a><a class="folder" href="%2E%2E/">folder &#8599;</a>'

        (ConvertTo-RdaBundleLink -Html $In -BundleRoot $Root) | Should -Be ('<span class="muted">no folder</span>' * 3)
    }

    It 'decodes an encoded folder name before it looks for the folder' {
        $Root = New-Run
        New-Item -ItemType Directory -Path (Join-Path $Root 'HTML a#b') -Force | Out-Null
        $In = '<a class="folder" href="HTML%20a%23b/">folder &#8599;</a>'
        (ConvertTo-RdaBundleLink -Html $In -BundleRoot $Root) | Should -Be $In
    }

    It 'keeps a Report link whose html is in the bundle and mutes one that is not, or that leaves its folder' {
        $Root = New-Run
        New-Item -ItemType Directory -Path (Join-Path $Root 'HTML_1') -Force | Out-Null
        'x' | Set-Content -LiteralPath (Join-Path $Root 'HTML_1/r a.html')
        $Keep = '<a href="HTML_1/r%20a.html">open &#8599;</a>'
        $Gone = @('<a href="HTML_2/r.html">open &#8599;</a>', '<a href="HTML_1/missing.html">open &#8599;</a>', '<a href="HTML_1/../HTML_1/r%20a.html">open &#8599;</a>', '<a href="HTML_1%2Fr%20a.html">open &#8599;</a>', '<a href="HTML_1">open &#8599;</a>')
        (ConvertTo-RdaBundleLink -Html ($Keep + ($Gone -join '')) -BundleRoot $Root) | Should -Be ($Keep + ('<span class="muted">no report</span>' * $Gone.Count))
    }

    It 'Copy-RdaBundleSummary: after the bundle is unzipped to a fresh folder every link resolves, and a row with no staged folder is muted' {
        $Run = New-Run
        $A = New-SubFolder -Root $Run -Services @{ VirtualMachines = 2 } -SubName 'Sub A'
        $B = New-SubFolder -Root $Run -Services @{ AppServices = 1 } -SubName 'Sub B' -NoHtml
        New-SubFolder -Root $Run -Services @{ AppServices = 1 } -SubName 'Sub C' | Out-Null   # left out of the bundle
        $Summary = Join-Path $Run 'MainSummary_x.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Summary | Out-Null
        $Stage = Join-Path $script:TmpRoot ('stage_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null

        Copy-RdaBundleSummary -MainSummaryFile $Summary -BundleStage $Stage -ReportFolders @((Get-Item -LiteralPath $A), (Get-Item -LiteralPath $B))

        $Zip = $Stage + '.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        $Fresh = $Stage + '_fresh'
        Expand-Archive -LiteralPath $Zip -DestinationPath $Fresh
        $Html = Get-Content -LiteralPath (Join-Path $Fresh 'MainSummary.html') -Raw
        $AHtml = 'HTML' + (Split-Path $A -Leaf).Substring('ResourcesReport'.Length)
        $Html | Should -Match ([regex]::Escape(('<a class="folder" href="{0}/">' -f $AHtml)))
        $Html | Should -Not -Match ('href="ResourcesReport') -Because 'every href points at a staged HTML folder'
        ([regex]::Matches($Html, '<span class="muted">no folder</span>')).Count | Should -Be 2 -Because 'the row with no html and the row left out have no staged folder'
        ([regex]::Matches($Html, '<span class="muted">no report</span>')).Count | Should -Be 2 -Because 'the row with no html, and the row left out of the bundle'
        ([regex]::Matches($Html, '>open &#8599;</a>')).Count | Should -Be 1
        foreach ($Href in @([regex]::Matches($Html, '<a (?:class="folder" )?href="([^"]+)">') | ForEach-Object { $_.Groups[1].Value }))
        {
            Test-Path -LiteralPath (Join-Path $Fresh ([uri]::UnescapeDataString($Href))) | Should -BeTrue -Because "link '$Href' must resolve after unzip"
        }
    }

    It 'Copy-RdaBundleSummary stages the html even when there is no summary file' {
        $Run = New-Run
        $A = New-SubFolder -Root $Run -Services @{ VirtualMachines = 1 } -SubName 'Sub A'
        $Stage = Join-Path $script:TmpRoot ('stage_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        Copy-RdaBundleSummary -MainSummaryFile $null -BundleStage $Stage -ReportFolders @(Get-Item -LiteralPath $A)
        @(Get-ChildItem -LiteralPath $Stage -Recurse -File).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $Stage 'MainSummary.html') | Should -BeFalse
    }

    It 'is what the wrapper calls for the bundle copy of the summary' {
        $Wrapper = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1') -Raw
        $Wrapper | Should -Match 'Copy-RdaBundleSummary -MainSummaryFile \$MainSummaryFile -BundleStage \$BundleStage'
        $Wrapper | Should -Match '\$BundleReportFolders = @\(Get-ChildItem -LiteralPath \$InventoryRoot ' -Because 'a [ or ] in the folder path is not a wildcard'
        $Wrapper | Should -Not -Match "-replace 'href=""ResourcesReport'" -Because 'the href rewrite lives in Copy-RdaBundleSummary only'
    }
}
