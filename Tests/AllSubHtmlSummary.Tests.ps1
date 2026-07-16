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
