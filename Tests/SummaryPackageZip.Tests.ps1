# =============================================================================
# Build-MainSummaryFromZip.ps1 -PackageZip contents.
#
# The portable bundle must hold only what this call reconstructed: the summary
# html and one ResourcesReport_<stamp>/ folder per per-subscription zip in the
# input. -OutputDirectory can be a folder that already holds other files, such
# as an earlier reconstruction, an obfuscation dictionary, a plain inventory,
# the wrapper's own per-subscription folders, or the wrapper's resume state
# file (.resume-state-<tenant>.json, which lists subscription ids). None of
# those may end up in the bundle. On Windows a leading dot does not hide a
# file, so a wildcard over the folder would pick up the resume state file too.
# The summary lists only the reconstructed folders, so every link in it
# resolves inside the bundle, and the other report folders are not rewritten.
#
# Runs the real script against a stand-in consolidated zip in the shape the
# wrapper writes. Offline; generic names and the documentation placeholder id.
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:Script = Join-Path $script:RepoRoot 'Build-MainSummaryFromZip.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('SummaryPackageZip_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null
    $script:PlaceholderId = '12345678-1234-1234-1234-123456789012'

    # One per-subscription report as ResourceInventory.ps1 names its files.
    function New-SubReportFiles
    {
        param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Stamp, [string]$SubName = 'Demo Subscription', [string]$Name = 'pip-demo')
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Base = 'ResourcesReport_' + $Stamp
        $Inv = [ordered]@{ Version = '3.2.3'; PublicIP = @([ordered]@{ Name = $Name; Subscription = $SubName; Location = 'eastus'; ResourceGroup = 'rg-demo' }) }
        ($Inv | ConvertTo-Json -Depth 6) | Out-File -FilePath (Join-Path $Dir ('Inventory_' + $Base + '.json')) -Encoding utf8
        '<!DOCTYPE html><html><body>per-subscription report</body></html>' | Out-File -FilePath (Join-Path $Dir ($Base + '.html')) -Encoding utf8
        'MeterCategory,Quantity' | Out-File -FilePath (Join-Path $Dir ('Consumption_' + $Base + '.csv')) -Encoding utf8
        '{"Metrics":[]}' | Out-File -FilePath (Join-Path $Dir ('Metrics_' + $Base + '.json')) -Encoding utf8
    }

    # Consolidated zip in the wrapper's shape: one ResourcesReport_<stamp>.zip
    # per subscription (flat members) plus RunSummary.log, MainSummary.html and
    # HTML<stamp>/ copies at the root. Returns the zip path and the stamps.
    # -Obfuscated names the resource and the subscription with prod_/nonprod_
    # tokens, as -Obfuscate writes them.
    function New-ConsolidatedZip
    {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Stamps, [switch]$Obfuscated)
        $Stage = Join-Path $Root ('outer_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        $Names = if ($Obfuscated) { @{ Name = 'prod_' + $script:PlaceholderId; SubName = 'nonprod_' + $script:PlaceholderId } } else { @{} }
        foreach ($Stamp in $Stamps)
        {
            $Src = Join-Path $Root ('sub_' + $Stamp)
            New-SubReportFiles -Dir $Src -Stamp $Stamp @Names
            Compress-Archive -Path (Join-Path $Src '*') -DestinationPath (Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')) -Force
            $HtmlDir = Join-Path $Stage ('HTML' + $Stamp)
            New-Item -ItemType Directory -Path $HtmlDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $Src ('ResourcesReport_' + $Stamp + '.html')) -Destination $HtmlDir
        }
        'run summary' | Out-File -FilePath (Join-Path $Stage 'RunSummary.log') -Encoding utf8
        '<!DOCTYPE html><html><body>bundled summary</body></html>' | Out-File -FilePath (Join-Path $Stage 'MainSummary.html') -Encoding utf8
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-05.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        return $Zip
    }

    # Entry names with '/' separators, file entries only.
    function Get-ZipEntryNames
    {
        param([Parameter(Mandatory)][string]$ZipPath)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try
        {
            @($Archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') -and -not $_.FullName.EndsWith('\') } | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object)
        }
        finally { $Archive.Dispose() }
    }

    # What this call reconstructs from the input: the summary plus, per
    # subscription, the report html and the inventory json.
    function Get-ExpectedEntries
    {
        param([Parameter(Mandatory)][string[]]$Stamps)
        $Names = @('MainSummary.html')
        foreach ($Stamp in $Stamps)
        {
            $Base = 'ResourcesReport_' + $Stamp
            $Names += ('{0}/{0}.html' -f $Base)
            $Names += ('{0}/Inventory_{0}.json' -f $Base)
        }
        @($Names | Sort-Object)
    }

    # The report links a summary html holds, with '/' separators, sorted. The
    # summary joins each link with Join-Path, so on Windows it holds '\'; a
    # '/' path resolves on every platform.
    function Get-SummaryLinkList
    {
        param([Parameter(Mandatory)][string]$HtmlPath)
        $Html = Get-Content -LiteralPath $HtmlPath -Raw
        @([regex]::Matches($Html, 'href="([^"]+\.html)"') | ForEach-Object { $_.Groups[1].Value.Replace('\', '/') } | Sort-Object)
    }

    # The links a summary of these stamps holds, one per reconstructed folder.
    function Get-ExpectedLinkList
    {
        param([Parameter(Mandatory)][string[]]$Stamps)
        @($Stamps | ForEach-Object { '{0}/{0}.html' -f ('ResourcesReport_' + $_) } | Sort-Object)
    }

    $script:Stamps = @('20260102030405001', '20260102030405002')
    $script:InputZip = New-ConsolidatedZip -Root $script:TmpRoot -Stamps $script:Stamps
}

AfterAll {
    if ($script:TmpRoot -and (Test-Path -LiteralPath $script:TmpRoot)) { Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Build-MainSummaryFromZip -PackageZip into a folder that already holds other files' {

    BeforeAll {
        # The wrapper's inventory root after a run, plus an earlier reconstruction.
        $script:Reused = Join-Path $script:TmpRoot 'InventoryReports'
        New-Item -ItemType Directory -Path $script:Reused -Force | Out-Null

        $script:Earlier = Join-Path $script:Reused 'ResourcesReport_20251201000000001'
        New-Item -ItemType Directory -Path $script:Earlier -Force | Out-Null
        '{"Version":"3.2.3"}' | Out-File -FilePath (Join-Path $script:Earlier 'Inventory_ResourcesReport_20251201000000001.json') -Encoding utf8
        '<html><body>earlier report</body></html>' | Out-File -FilePath (Join-Path $script:Earlier 'ResourcesReport_20251201000000001.html') -Encoding utf8

        $script:WrapperSub = Join-Path $script:Reused 'ResourcesReport20251201000000002'
        New-SubReportFiles -Dir $script:WrapperSub -Stamp '20251201000000002' -SubName 'Wrapper Subscription'
        '{"ResourceIdMap":{}}' | Out-File -FilePath (Join-Path $script:WrapperSub 'ObfuscationDictionary_ResourcesReport_20251201000000002.json') -Encoding utf8
        '{"data":[]}' | Out-File -FilePath (Join-Path $script:WrapperSub 'Full_ResourcesReport_20251201000000002.json') -Encoding utf8

        $script:Unrelated = @(
            (Join-Path $script:Reused 'ObfuscationDictionary_ResourcesReport_20251201000000003.json'),
            (Join-Path $script:Reused 'Inventory_ResourcesReport_20251201000000003.json'),
            (Join-Path $script:Reused ('.resume-state-{0}.json' -f $script:PlaceholderId))
        )
        '{"ResourceIdMap":{}}' | Out-File -FilePath $script:Unrelated[0] -Encoding utf8
        '{"Version":"3.2.3","PublicIP":[{"Name":"pip-plain"}]}' | Out-File -FilePath $script:Unrelated[1] -Encoding utf8
        ([ordered]@{ TenantID = $script:PlaceholderId; CompletedSubscriptionIds = @($script:PlaceholderId); FailedAttempts = @() } | ConvertTo-Json) |
            Out-File -FilePath $script:Unrelated[2] -Encoding utf8

        # The html of the report folders this call does not reconstruct.
        $script:OtherHtml = @(Get-ChildItem -LiteralPath $script:Earlier, $script:WrapperSub -Filter '*.html' -File | ForEach-Object { $_.FullName })
        $script:OtherHashBefore = @($script:OtherHtml | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })

        & $script:Script -InputZip $script:InputZip -OutputDirectory $script:Reused -PackageZip 6>$null | Out-Null
        $script:Package = $script:Reused.TrimEnd([IO.Path]::DirectorySeparatorChar) + '.zip'
        $script:Entries = if (Test-Path -LiteralPath $script:Package) { Get-ZipEntryNames -ZipPath $script:Package } else { @() }
        $script:ReusedExtract = Join-Path $script:TmpRoot 'reused_extracted'
        if (Test-Path -LiteralPath $script:Package) { Expand-Archive -LiteralPath $script:Package -DestinationPath $script:ReusedExtract -Force }
    }

    It 'writes the package next to the folder' {
        Test-Path -LiteralPath $script:Package | Should -BeTrue
    }

    It 'holds exactly the summary and the folders reconstructed from the input zip' {
        $script:Entries | Should -Be (Get-ExpectedEntries -Stamps $script:Stamps)
    }

    It 'leaves out the earlier reconstruction, the wrapper folder, the dictionary and the plain inventory' {
        @($script:Entries | Where-Object { $_ -like 'ResourcesReport_20251201000000001/*' }) | Should -BeNullOrEmpty
        @($script:Entries | Where-Object { $_ -like 'ResourcesReport20251201000000002/*' }) | Should -BeNullOrEmpty
        @($script:Entries | Where-Object { $_ -like '*ObfuscationDictionary_*' -or $_ -like '*Full_*' }) | Should -BeNullOrEmpty
        @($script:Entries | Where-Object { $_ -notlike '*/*' -and $_ -like 'Inventory_*' }) | Should -BeNullOrEmpty
    }

    It 'never includes the resume state file' {
        @($script:Entries | Where-Object { (Split-Path -Path $_ -Leaf) -like '.resume-state*' }) | Should -BeNullOrEmpty
    }

    It 'leaves the other files in the folder in place' {
        foreach ($File in $script:Unrelated) { Test-Path -LiteralPath $File | Should -BeTrue }
        Test-Path -LiteralPath $script:Earlier | Should -BeTrue
        Test-Path -LiteralPath $script:WrapperSub | Should -BeTrue
    }

    It 'lists only the folders reconstructed from the input zip in the packaged summary' {
        $Summary = Join-Path $script:ReusedExtract 'MainSummary.html'
        Get-SummaryLinkList -HtmlPath $Summary | Should -Be (Get-ExpectedLinkList -Stamps $script:Stamps)
        $Html = Get-Content -LiteralPath $Summary -Raw
        $Html | Should -Not -Match 'Wrapper Subscription' -Because 'the wrapper folder is not in the input zip'
        $Html | Should -Not -Match 'ResourcesReport_?20251201' -Because 'neither earlier folder is in the input zip'
    }

    It 'keeps every packaged summary link resolvable after extraction' {
        $Links = @(Get-SummaryLinkList -HtmlPath (Join-Path $script:ReusedExtract 'MainSummary.html'))
        $Links.Count | Should -Be $script:Stamps.Count
        foreach ($Link in $Links) { Test-Path -LiteralPath (Join-Path $script:ReusedExtract $Link) | Should -BeTrue -Because "'$Link' is in the package" }
    }

    It 'leaves the html of the report folders it did not reconstruct byte-identical' {
        $script:OtherHtml.Count | Should -Be 2
        @($script:OtherHtml | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }) | Should -Be $script:OtherHashBefore
    }

    Context 'with an obfuscated input zip and a plain report folder already in the output folder' {

        BeforeAll {
            $Root = Join-Path $script:TmpRoot 'obfuscated'
            # Three subscriptions: were the plain folder listed, its samples
            # would not outweigh the tokens, and the obfuscated banner would
            # sit over its plain subscription name.
            $script:ObfStamps = @('20260102030405011', '20260102030405012', '20260102030405013')
            $script:ObfZip = New-ConsolidatedZip -Root $Root -Stamps $script:ObfStamps -Obfuscated
            $script:ObfOut = Join-Path $Root 'InventoryReports'
            $script:Plain = Join-Path $script:ObfOut 'ResourcesReport20251201000000009'
            New-SubReportFiles -Dir $script:Plain -Stamp '20251201000000009' -SubName 'Plain Outside Subscription' -Name 'pip-plain-outside'
            $script:PlainHtml = Join-Path $script:Plain 'ResourcesReport_20251201000000009.html'
            $script:PlainHashBefore = (Get-FileHash -LiteralPath $script:PlainHtml -Algorithm SHA256).Hash

            & $script:Script -InputZip $script:ObfZip -OutputDirectory $script:ObfOut -PackageZip 6>$null | Out-Null
            $script:ObfPackage = $script:ObfOut + '.zip'
            $script:ObfExtract = Join-Path $Root 'extracted'
            if (Test-Path -LiteralPath $script:ObfPackage) { Expand-Archive -LiteralPath $script:ObfPackage -DestinationPath $script:ObfExtract -Force }
        }

        It 'holds no name from the plain folder in the packaged summary, which still shows the obfuscated banner' {
            $Html = Get-Content -LiteralPath (Join-Path $script:ObfExtract 'MainSummary.html') -Raw
            $Html | Should -Not -Match 'Plain Outside Subscription'
            $Html | Should -Not -Match 'ResourcesReport_?20251201000000009'
            $Html | Should -Match 'class="privacy-banner obfuscated"'
            Get-SummaryLinkList -HtmlPath (Join-Path $script:ObfExtract 'MainSummary.html') | Should -Be (Get-ExpectedLinkList -Stamps $script:ObfStamps)
        }

        It 'keeps every packaged summary link resolvable after extraction' {
            $Links = @(Get-SummaryLinkList -HtmlPath (Join-Path $script:ObfExtract 'MainSummary.html'))
            $Links.Count | Should -Be $script:ObfStamps.Count
            foreach ($Link in $Links) { Test-Path -LiteralPath (Join-Path $script:ObfExtract $Link) | Should -BeTrue -Because "'$Link' is in the package" }
        }

        It 'leaves the plain folder''s html byte-identical' {
            (Get-FileHash -LiteralPath $script:PlainHtml -Algorithm SHA256).Hash | Should -Be $script:PlainHashBefore
        }
    }
}

Describe 'Build-MainSummaryFromZip -PackageZip over a folder of the same name that holds other files' {

    BeforeAll {
        # The output folder already holds a folder named like one this call
        # rebuilds, with a revealed report and older files in it.
        $script:Same = Join-Path $script:TmpRoot 'same_name'
        $Base = 'ResourcesReport_' + $script:Stamps[0]
        $script:SameDir = Join-Path $script:Same $Base
        New-Item -ItemType Directory -Path $script:SameDir -Force | Out-Null
        $script:Stale = @(
            ($Base + '_revealed.html'),
            ('Inventory_' + $Base + '_revealed.json'),
            'old-report.html',
            ('Consumption_' + $Base + '.csv')
        )
        foreach ($Name in $script:Stale) { 'real names from an earlier call' | Out-File -FilePath (Join-Path $script:SameDir $Name) -Encoding utf8 }
        # A valid inventory of an earlier call, named so it sorts first.
        $script:StaleInventory = 'Inventory_000.json'
        '{"Version":"3.2.3","PublicIP":[{"Name":"pip-stale","Subscription":"Stale Real Subscription"}]}' | Out-File -FilePath (Join-Path $script:SameDir $script:StaleInventory) -Encoding utf8
        $script:Stale += $script:StaleInventory

        & $script:Script -InputZip $script:InputZip -OutputDirectory $script:Same -PackageZip 6>$null | Out-Null
        $script:SamePackage = $script:Same + '.zip'
        $script:SameEntries = if (Test-Path -LiteralPath $script:SamePackage) { Get-ZipEntryNames -ZipPath $script:SamePackage } else { @() }
        $script:SameExtract = Join-Path $script:TmpRoot 'same_name_extracted'
        if (Test-Path -LiteralPath $script:SamePackage) { Expand-Archive -LiteralPath $script:SamePackage -DestinationPath $script:SameExtract -Force }
    }

    It 'reads only the rebuilt files for the summary: no name from a file already there, and every link resolves in the bundle' {
        $Summary = Join-Path $script:SameExtract 'MainSummary.html'
        Get-Content -LiteralPath $Summary -Raw | Should -Not -Match 'Stale Real Subscription'
        Get-SummaryLinkList -HtmlPath $Summary | Should -Be (Get-ExpectedLinkList -Stamps $script:Stamps)
        foreach ($Link in @(Get-SummaryLinkList -HtmlPath $Summary)) { Test-Path -LiteralPath (Join-Path $script:SameExtract $Link) | Should -BeTrue }
    }

    It 'holds exactly the summary and the files rebuilt from the input zip, none of the files already there' {
        $script:SameEntries | Should -Be (Get-ExpectedEntries -Stamps $script:Stamps)
    }

    It 'leaves the files already in the folder in place' {
        foreach ($Name in $script:Stale) { Test-Path -LiteralPath (Join-Path $script:SameDir $Name) | Should -BeTrue }
    }
}

Describe 'Build-MainSummaryFromZip -PackageZip into a new folder' {

    BeforeAll {
        $script:Fresh = Join-Path $script:TmpRoot 'fresh_MainSummary'
        & $script:Script -InputZip $script:InputZip -OutputDirectory $script:Fresh -PackageZip 6>$null | Out-Null
        $script:FreshPackage = $script:Fresh + '.zip'
    }

    It 'holds the summary and every reconstructed folder' {
        Get-ZipEntryNames -ZipPath $script:FreshPackage | Should -Be (Get-ExpectedEntries -Stamps $script:Stamps)
    }

    It 'keeps every summary link resolvable after extraction elsewhere' {
        $Extract = Join-Path $script:TmpRoot 'extracted'
        Expand-Archive -LiteralPath $script:FreshPackage -DestinationPath $Extract -Force
        $Html = Get-Content -LiteralPath (Join-Path $Extract 'MainSummary.html') -Raw
        $Links = @([regex]::Matches($Html, 'href="([^"]+\.html)"') | ForEach-Object { $_.Groups[1].Value })
        $Links.Count | Should -Be $script:Stamps.Count
        foreach ($Link in $Links) { Test-Path -LiteralPath (Join-Path $Extract $Link) | Should -BeTrue -Because "'$Link' is in the package" }
    }
}

Describe 'Build-MainSummaryFromZip with two report zips of the same name in the input' {

    BeforeAll {
        $Root = Join-Path $script:TmpRoot 'twice'
        $Stage = Join-Path $Root 'outer'
        $Stamp = '20260102030405021'
        $Src = Join-Path $Root 'sub'
        New-SubReportFiles -Dir $Src -Stamp $Stamp
        foreach ($Sub in 'a', 'b')
        {
            $Dir = Join-Path $Stage $Sub
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            Compress-Archive -Path (Join-Path $Src '*') -DestinationPath (Join-Path $Dir ('ResourcesReport_' + $Stamp + '.zip')) -Force
        }
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-06.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        $script:TwiceOut = Join-Path $Root 'out'
        $script:TwiceLines = @(& $script:Script -InputZip $Zip -OutputDirectory $script:TwiceOut 6>&1 | ForEach-Object { [string]$_ })
    }

    It 'rebuilds the report once, says so, and counts it once' {
        @($script:TwiceLines | Where-Object { $_ -like '*Skipped a second report zip named ResourcesReport_20260102030405021.zip*' }).Count | Should -Be 1
        @($script:TwiceLines | Where-Object { $_ -like 'Reconstructed 1 per-subscription report(s) into:*' }).Count | Should -Be 1
    }
}

Describe 'Build-MainSummaryFromZip with two extracted report folders of the same name in the input' {

    BeforeAll {
        $Root = Join-Path $script:TmpRoot 'twice_folders'
        $Stage = Join-Path $Root 'outer'
        $Stamp = '20260102030405031'
        foreach ($Sub in 'a', 'b') { New-SubReportFiles -Dir (Join-Path $Stage ('{0}/ResourcesReport_{1}' -f $Sub, $Stamp)) -Stamp $Stamp -SubName ('Sub ' + $Sub) }
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-07.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        $script:TwiceFolderLines = @(& $script:Script -InputZip $Zip -OutputDirectory (Join-Path $Root 'out') 6>&1 | ForEach-Object { [string]$_ })
    }

    It 'rebuilds the folder once, says so, and counts it once' {
        @($script:TwiceFolderLines | Where-Object { $_ -like '*Skipped a second report folder named ResourcesReport_20260102030405031 in the input zip*' }).Count | Should -Be 1
        @($script:TwiceFolderLines | Where-Object { $_ -like 'Reconstructed 1 per-subscription report(s) into:*' }).Count | Should -Be 1
    }
}

Describe 'Build-MainSummaryFromZip report zips whose names differ only in case' {

    BeforeAll {
        $Root = Join-Path $script:TmpRoot 'case'
        $Stage = Join-Path $Root 'outer'
        $Stamp = '20260102030405041'
        $Src = Join-Path $Root 'sub'
        New-SubReportFiles -Dir $Src -Stamp $Stamp
        New-Item -ItemType Directory -Path (Join-Path $Stage 'a'), (Join-Path $Stage 'b') -Force | Out-Null
        Compress-Archive -Path (Join-Path $Src '*') -DestinationPath (Join-Path $Stage ('a/ResourcesReport_' + $Stamp + '.zip')) -Force
        Compress-Archive -Path (Join-Path $Src '*') -DestinationPath (Join-Path $Stage ('b/resourcesreport_' + $Stamp + '.zip')) -Force
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-08.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        $script:CaseOut = Join-Path $Root 'out'
        $script:CaseLines = @(& $script:Script -InputZip $Zip -OutputDirectory $script:CaseOut 6>&1 | ForEach-Object { [string]$_ })
        . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
    }

    It 'treats them as one folder where the file system ignores case, and rebuilds it once' {
        if (-not (Get-RdaPathComparer -Path $script:CaseOut).Equals('A', 'a')) { Set-ItResult -Skipped -Because 'this file system keeps case apart' }
        @($script:CaseLines | Where-Object { $_ -like '*Skipped a second report zip named*' }).Count | Should -Be 1
        @($script:CaseLines | Where-Object { $_ -like 'Reconstructed 1 per-subscription report(s) into:*' }).Count | Should -Be 1
    }

    It 'treats them as two folders where the file system keeps case apart, and lists both in the summary' {
        if ((Get-RdaPathComparer -Path $script:CaseOut).Equals('A', 'a')) { Set-ItResult -Skipped -Because 'this file system ignores case' }
        @($script:CaseLines | Where-Object { $_ -like '*Skipped a second report zip named*' }) | Should -BeNullOrEmpty
        @($script:CaseLines | Where-Object { $_ -like 'Reconstructed 2 per-subscription report(s) into:*' }).Count | Should -Be 1
        @($script:CaseLines | Where-Object { $_ -like '  2 subscription(s), *' }).Count | Should -Be 1
    }
}

Describe 'Build-MainSummaryFromZip -PackageZip with -HtmlFile given through a PowerShell drive' {
    It 'puts the summary in the bundle' {
        $Out = Join-Path $script:TmpRoot 'drive_out'
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        $null = New-PSDrive -Name RdaPkg -PSProvider FileSystem -Root $Out -Scope Global
        try
        {
            . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
            New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory 'RdaPkg:\' -HtmlFile 'RdaPkg:\MainSummary.html' -PackageZip 6>$null | Out-Null
        }
        finally { Remove-PSDrive -Name RdaPkg -Scope Global -ErrorAction SilentlyContinue }
        $Package = $Out.TrimEnd([IO.Path]::DirectorySeparatorChar) + '.zip'
        Get-ZipEntryNames -ZipPath $Package | Should -Contain 'MainSummary.html'
    }
}

Describe 'Build-MainSummaryFromZip over a folder whose name differs from a rebuilt one only in case (Linux)' -Skip:(-not $IsLinux) {
    It 'does not list the other folder: on Linux it is another folder' {
        $Out = Join-Path $script:TmpRoot 'case_linux'
        $Other = Join-Path $Out ('resourcesreport_' + $script:Stamps[0])
        New-Item -ItemType Directory -Path $Other -Force | Out-Null
        '{"Version":"3.2.3","PublicIP":[{"Name":"pip-old","Subscription":"Other Case Subscription"}]}' | Out-File -FilePath (Join-Path $Other ('Inventory_resourcesreport_' + $script:Stamps[0] + '.json')) -Encoding utf8
        & $script:Script -InputZip $script:InputZip -OutputDirectory $Out 6>$null | Out-Null
        Get-Content -LiteralPath (Join-Path $Out 'MainSummary.html') -Raw | Should -Not -Match 'Other Case Subscription'
    }
}

Describe 'Build-MainSummaryFromZip -PackageZip whose bundle would be the input zip' {
    It 'stops before it changes anything and leaves the input zip as it was' {
        $Root = Join-Path $script:TmpRoot 'collide'
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $In = Join-Path $Root 'report.zip'
        Copy-Item -LiteralPath $script:InputZip -Destination $In
        $Hash = (Get-FileHash -LiteralPath $In).Hash
        { & $script:Script -InputZip $In -OutputDirectory (Join-Path $Root 'report') -PackageZip 6>$null } | Should -Throw '*-PackageZip would write*which is -InputZip*'
        (Get-FileHash -LiteralPath $In).Hash | Should -Be $Hash
    }
}

Describe 'Build-MainSummaryFromZip -PackageZip when the bundle cannot be written' {
    It 'leaves no part-written bundle beside the name' {
        $Out = Join-Path $script:TmpRoot 'pkg_fail'
        # A folder under the bundle's name: the move onto it fails.
        New-Item -ItemType Directory -Path ($Out + '.zip') -Force | Out-Null
        { & $script:Script -InputZip $script:InputZip -OutputDirectory $Out -PackageZip 6>$null } | Should -Throw
        @(Get-ChildItem -LiteralPath $script:TmpRoot -File | Where-Object { $_.Name -like 'pkg_fail.zip.rda-*.partial' }) | Should -BeNullOrEmpty
    }
}

Describe 'Get-RdaPathComparer: the case behaviour of the file system where a path is' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'compares exactly where the file system keeps case apart (a twin name finds nothing)' {
        $Dir = Join-Path $TestDrive 'CaseProbe'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Mock Test-Path { $LiteralPath -ceq $Dir -or $LiteralPath -ceq (Split-Path $Dir -Parent) }
        (Get-RdaPathComparer -Path $Dir).Equals('A', 'a') | Should -BeFalse
    }

    It 'compares case aside where the file system ignores case (the twin name finds the same folder, which is listed once)' {
        $Dir = Join-Path $TestDrive 'CaseProbe2'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        # What a case-insensitive mount answers for the flipped name.
        Mock Test-Path { $true }
        (Get-RdaPathComparer -Path $Dir).Equals('A', 'a') | Should -BeTrue
    }

    It 'compares exactly where two items differ only in case (the twin is a second item)' {
        $Dir = Join-Path $TestDrive 'Twin'
        New-Item -ItemType Directory -Path $Dir, (Join-Path $TestDrive 'tWIN') -Force | Out-Null
        if (@(Get-ChildItem -LiteralPath $TestDrive -Directory | Where-Object { $_.Name -ieq 'twin' }).Count -lt 2) { Set-ItResult -Skipped -Because 'this file system ignores case' }
        (Get-RdaPathComparer -Path $Dir).Equals('A', 'a') | Should -BeFalse
    }
}

Describe 'Get-RdaPathComparer with a path typed in another letter case' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'still finds a file system that ignores case when the path is typed as the flipped spelling of the name on disk' {
        $Root = Join-Path $TestDrive 'typed'
        New-Item -ItemType Directory -Path (Join-Path $Root 'OUTX') -Force | Out-Null
        # What a case-insensitive file system answers: every spelling finds it
        # (the path is probed as a name in its folder here).
        Mock Test-Path { $PathType -ne 'Container' }
        (Get-RdaPathComparer -Path (Join-Path $Root 'outx')).Equals('A', 'a') | Should -BeTrue
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip with -HtmlFile outside -OutputDirectory' {
    It 'stops, since the summary''s links point at report folders beside it' {
        . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
        $Out = Join-Path $script:TmpRoot 'html_elsewhere'
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -HtmlFile (Join-Path $script:TmpRoot 'elsewhere.html') -PackageZip 6>$null } | Should -Throw '*-HtmlFile must be in -OutputDirectory*'
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip checks a zip before it extracts it' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
        function script:New-RawZip
        {
            param([string]$Path, [scriptblock]$Fill)
            $Zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
            try { & $Fill $Zip } finally { $Zip.Dispose() }
            $Path
        }
    }

    It 'refuses a zip with more than 2000 entries, an entry path with .., or one packed more than 100 to 1 (<Case>)' -ForEach @(
        @{ Case = 'entries'; Like = '*more than 2000*'; Fill = { param($Z) foreach ($N in 1..2001) { $null = $Z.CreateEntry("e$N.txt") } } }
        @{ Case = 'dotdot'; Like = '*rooted or .. path*'; Fill = { param($Z) $null = $Z.CreateEntry('../escape.txt') } }
        @{ Case = 'ratio'; Like = '*more than 100 to 1*'; Fill = { param($Z) $E = $Z.CreateEntry('zeros.bin', 'Optimal'); $W = $E.Open(); try { $B = [byte[]]::new(1MB); foreach ($N in 1..8) { $W.Write($B, 0, $B.Length) } } finally { $W.Dispose() } } }
    ) {
        $Path = New-RawZip -Path (Join-Path $script:TmpRoot ('limits-' + $Case + '.zip')) -Fill $Fill
        $Out = Join-Path $script:TmpRoot ('limits-out-' + $Case)
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Path -OutputDirectory $Out 6>$null } | Should -Throw $Like
        Test-Path -LiteralPath $Out | Should -BeFalse -Because 'a refused zip creates nothing'
    }

    It 'extracts into a new staging folder of its own, readable by this user only on Linux and macOS' -Skip:($IsWindows) {
        # stat reads the mode on every .NET (GetUnixFileMode needs .NET 7).
        Mock Expand-Archive { $script:StagingMode = (& stat -c '%a' $DestinationPath 2>$null); if (-not $script:StagingMode) { $script:StagingMode = (& stat -f '%Lp' $DestinationPath) }; throw 'stop here' }
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory (Join-Path $script:TmpRoot 'staging-mode') 6>$null } | Should -Throw '*stop here*'
        $script:StagingMode | Should -Be '700'
    }

    It 'does not count a report zip that holds no inventory, and says no report was found when that is all there is' {
        $Root = Join-Path $script:TmpRoot 'no-inventory'
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        $null = New-RawZip -Path (Join-Path $Stage 'ResourcesReport_20260102030405051.zip') -Fill { param($Z) $E = $Z.CreateEntry('ResourcesReport_20260102030405051.html'); $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write('<html></html>') } finally { $W.Dispose() } }
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-09.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory (Join-Path $Root 'out') 6>$null } | Should -Throw '*no per-subscription reports found*'
        Test-Path -LiteralPath (Join-Path $Root 'out') | Should -BeFalse -Because 'a refused rebuild leaves no folder it made'
    }
}

Describe 'Get-RdaPathComparer and Get-RdaOnDiskName in an empty or reused folder' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'probes inside an empty folder with a probe file it removes again' {
        $Dir = Join-Path $TestDrive 'empty-probe'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Mock Test-Path { $LiteralPath -like '*rda-case-*-Probe.tmp' -or (-not $PathType) -or $PathType -eq 'Container' } -ParameterFilter { $LiteralPath -like '*rda-case-*' }
        $null = Get-RdaPathComparer -Path $Dir
        Should -Invoke Test-Path -ParameterFilter { $LiteralPath -like '*rda-case-*' }
        @(Get-ChildItem -LiteralPath $Dir -Force) | Should -BeNullOrEmpty
    }

    It 'gives a name with the letter case it has on disk' {
        $Dir = Join-Path $TestDrive 'ondisk'
        New-Item -ItemType Directory -Path (Join-Path $Dir 'ResourcesReport_X') -Force | Out-Null
        Get-RdaOnDiskName -Path (Join-Path $Dir 'resourcesreport_x') | Should -BeExactly 'ResourcesReport_X'
        Get-RdaOnDiskName -Path (Join-Path $Dir 'ResourcesReport_X') | Should -BeExactly 'ResourcesReport_X'
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip writes within one budget, and only real reports' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
        function script:New-InnerZip
        {
            param([string]$Path, [string]$Stamp, [int]$ExtraHtml = 0, [switch]$NoInventory, [string]$Html = '<html>new</html>')
            $Zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
            try
            {
                $Put = { param($Name, $Text) $E = $Zip.CreateEntry($Name); $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write($Text) } finally { $W.Dispose() } }
                if (-not $NoInventory) { & $Put ('Inventory_ResourcesReport_' + $Stamp + '.json') '{"Version":"3.2.3","PublicIP":[{"Name":"pip","Subscription":"Sub"}]}' }
                & $Put ('ResourcesReport_' + $Stamp + '.html') $Html
                foreach ($N in 1..$ExtraHtml) { & $Put ('extra-' + $N + '.html') 'x' }
            }
            finally { $Zip.Dispose() }
        }
    }

    It 'stops before writing anything when the report zips together hold more than 2000 files to write' {
        $Root = Join-Path $script:TmpRoot 'budget'
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        New-InnerZip -Path (Join-Path $Stage 'ResourcesReport_20260102030405061.zip') -Stamp '20260102030405061' -ExtraHtml 1000
        New-InnerZip -Path (Join-Path $Stage 'ResourcesReport_20260102030405062.zip') -Stamp '20260102030405062' -ExtraHtml 1000
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-10.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        $Out = Join-Path $Root 'out'
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null } | Should -Throw '*more than 2000 files in all*'
        @(Get-ChildItem -LiteralPath $Out -Recurse -File -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }

    It 'leaves a file already in the folder alone when a report zip of that name holds no inventory' {
        $Root = Join-Path $script:TmpRoot 'html-only'
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        New-InnerZip -Path (Join-Path $Stage 'ResourcesReport_20260102030405071.zip') -Stamp '20260102030405071'
        New-InnerZip -Path (Join-Path $Stage 'ResourcesReport_20260102030405072.zip') -Stamp '20260102030405072' -NoInventory
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-11.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        $Out = Join-Path $Root 'out'
        $Kept = Join-Path $Out 'ResourcesReport_20260102030405072/ResourcesReport_20260102030405072.html'
        New-Item -ItemType Directory -Path (Split-Path $Kept -Parent) -Force | Out-Null
        Set-Content -LiteralPath $Kept -Value 'an earlier report' -NoNewline
        New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null | Out-Null
        Get-Content -LiteralPath $Kept -Raw | Should -Be 'an earlier report'
    }

    It 'keeps the extracted report html when the re-render fails part-way' {
        # A copy of the functions beside a stand-in renderer that writes part of its file, then fails.
        $Tree = Join-Path $script:TmpRoot 'render-tree'
        New-Item -ItemType Directory -Path (Join-Path $Tree 'Functions'), (Join-Path $Tree 'Extension') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') -Destination (Join-Path $Tree 'Functions')
        Set-Content -LiteralPath (Join-Path $Tree 'Extension/Summary.ps1') -Value 'param($JsonFile, $HtmlFile, $Title, $Version, $PlatOS) Set-Content -LiteralPath $HtmlFile -Value "<html>part"; throw "renderer failed"'
        . (Join-Path $Tree 'Functions/AllSubHtmlSummary.Functions.ps1')
        $Root = Join-Path $script:TmpRoot 'render'
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        New-InnerZip -Path (Join-Path $Stage 'ResourcesReport_20260102030405081.zip') -Stamp '20260102030405081' -Html '<html>original</html>'
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-12.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        $Out = Join-Path $Root 'out'
        New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null | Out-Null
        Get-Content -LiteralPath (Join-Path $Out 'ResourcesReport_20260102030405081/ResourcesReport_20260102030405081.html') -Raw | Should -Be '<html>original</html>'
        @(Get-ChildItem -LiteralPath (Join-Path $Out 'ResourcesReport_20260102030405081') -Filter '*.partial') | Should -BeNullOrEmpty
        . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip counts the files it renders in its budget' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'stops when report zips with only an inventory, their rendered html and the summary come to more than 2000 files' {
        $Root = Join-Path $script:TmpRoot 'render-budget'
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        foreach ($N in 1..1000)
        {
            $Stamp = '2026010203{0:D7}' -f $N
            $Zip = [System.IO.Compression.ZipFile]::Open((Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
            try { $E = $Zip.CreateEntry('Inventory_ResourcesReport_' + $Stamp + '.json'); $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write('{"Version":"3.2.3"}') } finally { $W.Dispose() } } finally { $Zip.Dispose() }
        }
        $Outer = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-13.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, $Outer)
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer -OutputDirectory (Join-Path $Root 'out') 6>$null } | Should -Throw '*more than 2000 files in all*'
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip budget for extracted folders, the bundle check and the summary write' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'plans extracted report folders against the same budget, writing nothing when they pass it' {
        $Root = Join-Path $script:TmpRoot 'folder-budget'
        $Stage = Join-Path $Root 'outer'
        foreach ($N in 1..1000)
        {
            $Stamp = '2026010204{0:D7}' -f $N
            $Dir = Join-Path $Stage ('ResourcesReport_' + $Stamp)
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Dir ('Inventory_ResourcesReport_' + $Stamp + '.json')) -Value '{"Version":"3.2.3"}'
        }
        $Outer = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-14.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, $Outer)
        $Out = Join-Path $Root 'out'
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer -OutputDirectory $Out 6>$null } | Should -Throw '*more than 2000 files in all*'
        Test-Path -LiteralPath $Out | Should -BeFalse -Because 'a refused rebuild leaves no folder it made'
    }

    It 'checks the bundle as written with the report zip limits, and leaves no bundle when it fails them' {
        $Root = Join-Path $script:TmpRoot 'bundle-ratio'
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        $Stamp = '20260102030405091'
        # The inventory stored without compression: inside limits as given,
        # but the bundle packs it far tighter than 100 to 1.
        $Inner = [System.IO.Compression.ZipFile]::Open((Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
        try
        {
            $E = $Inner.CreateEntry('Inventory_ResourcesReport_' + $Stamp + '.json', 'NoCompression')
            $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write('{"Version":"3.2.3"' + (' ' * 4MB) + '}') } finally { $W.Dispose() }
        }
        finally { $Inner.Dispose() }
        $Outer = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-15.zip'
        $O = [System.IO.Compression.ZipFile]::Open($Outer, 'Create'); try { $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($O, (Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')), ('ResourcesReport_' + $Stamp + '.zip'), 'NoCompression') } finally { $O.Dispose() }
        $Out = Join-Path $Root 'out'
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer -OutputDirectory $Out -PackageZip -KeepOriginalReports 6>$null } | Should -Throw '*more than 100 to 1*'
        Test-Path -LiteralPath ($Out + '.zip') | Should -BeFalse
    }

    It 'keeps an earlier main summary whole when writing the new one fails' {
        $Run = Join-Path $script:TmpRoot 'summary-write'
        $Dir = Join-Path $Run 'ResourcesReport_20260102030405095'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        '{"Version":"3.2.3","PublicIP":[{"Name":"pip","Subscription":"Sub"}]}' | Set-Content -LiteralPath (Join-Path $Dir 'Inventory_ResourcesReport_20260102030405095.json')
        $Html = Join-Path $Run 'MainSummary.html'
        Set-Content -LiteralPath $Html -Value 'an earlier summary' -NoNewline
        Mock Out-File { Set-Content -LiteralPath $FilePath -Value '<html>part'; throw 'disk full' } -RemoveParameterType Encoding
        { New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Html 6>$null } | Should -Throw '*disk full*'
        Get-Content -LiteralPath $Html -Raw | Should -Be 'an earlier summary'
        @(Get-ChildItem -LiteralPath $Run -Filter '*.partial') | Should -BeNullOrEmpty
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip over a reused folder when a write fails part-way, and the folders a refusal leaves' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
        $script:EarlierInv = '{"Version":"3.2.3","PublicIP":[{"Name":"earlier","Subscription":"Sub"}]}'
        function script:New-EarlierReport
        {
            param([string]$Out, [string]$Stamp)
            $Dir = Join-Path $Out ('ResourcesReport_' + $Stamp)
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Dir ('Inventory_ResourcesReport_' + $Stamp + '.json')) -Value $script:EarlierInv -NoNewline
            Set-Content -LiteralPath (Join-Path $Dir ('ResourcesReport_' + $Stamp + '.html')) -Value '<html>earlier</html>' -NoNewline
            $Dir
        }
    }

    It 'keeps an earlier report whole when a report zip entry cannot be read' {
        $Root = Join-Path $script:TmpRoot 'reuse-zip-fail'
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        $Stamp = '20260102030405101'
        $InnerPath = Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')
        $Inner = [System.IO.Compression.ZipFile]::Open($InnerPath, 'Create')
        try
        {
            $E = $Inner.CreateEntry('ResourcesReport_' + $Stamp + '.html'); $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write('<html>new</html>') } finally { $W.Dispose() }
            $E = $Inner.CreateEntry('Inventory_ResourcesReport_' + $Stamp + '.json', 'Optimal'); $W = [System.IO.StreamWriter]::new($E.Open())
            try { $R = [Random]::new(1); foreach ($N in 1..20000) { $W.Write([char](65 + $R.Next(26))) } } finally { $W.Dispose() }
        }
        finally { $Inner.Dispose() }
        # Spoil the inventory's packed data, so reading it fails part-way.
        $Bytes = [System.IO.File]::ReadAllBytes($InnerPath)
        $Start = [System.Text.Encoding]::ASCII.GetString($Bytes).IndexOf('Inventory_ResourcesReport_' + $Stamp + '.json') + 60
        foreach ($K in $Start..($Start + 300)) { $Bytes[$K] = 255 }
        [System.IO.File]::WriteAllBytes($InnerPath, $Bytes)
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-20.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        $Out = Join-Path $Root 'out'
        $Dir = New-EarlierReport -Out $Out -Stamp $Stamp
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null } | Should -Throw
        Get-Content -LiteralPath (Join-Path $Dir ('Inventory_ResourcesReport_' + $Stamp + '.json')) -Raw | Should -Be $script:EarlierInv
        Get-Content -LiteralPath (Join-Path $Dir ('ResourcesReport_' + $Stamp + '.html')) -Raw | Should -Be '<html>earlier</html>'
        @(Get-ChildItem -LiteralPath $Out -Recurse -Filter '*.partial') | Should -BeNullOrEmpty
    }

    It 'keeps an earlier report whole when copying an extracted report folder fails part-way' {
        $Root = Join-Path $script:TmpRoot 'reuse-copy-fail'
        $Stamp = '20260102030405102'
        $Stage = Join-Path $Root 'outer'
        $Src = Join-Path $Stage ('ResourcesReport_' + $Stamp)
        New-Item -ItemType Directory -Path $Src -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Src ('Inventory_ResourcesReport_' + $Stamp + '.json')) -Value '{"Version":"3.2.3"}'
        Set-Content -LiteralPath (Join-Path $Src ('ResourcesReport_' + $Stamp + '.html')) -Value '<html>new</html>'
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-21.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, $Zip)
        $Out = Join-Path $Root 'out'
        $Dir = New-EarlierReport -Out $Out -Stamp $Stamp
        Mock Copy-Item { Set-Content -LiteralPath $Destination -Value 'part'; throw 'disk full' }
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null } | Should -Throw '*disk full*'
        Get-Content -LiteralPath (Join-Path $Dir ('Inventory_ResourcesReport_' + $Stamp + '.json')) -Raw | Should -Be $script:EarlierInv
        Get-Content -LiteralPath (Join-Path $Dir ('ResourcesReport_' + $Stamp + '.html')) -Raw | Should -Be '<html>earlier</html>'
        @(Get-ChildItem -LiteralPath $Out -Recurse -Filter '*.partial') | Should -BeNullOrEmpty
    }

    It 'leaves no folder it made when -HtmlFile is outside -OutputDirectory' {
        $Out = Join-Path $script:TmpRoot 'html-elsewhere-clean'
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -HtmlFile (Join-Path $script:TmpRoot 'elsewhere2.html') 6>$null } | Should -Throw '*-HtmlFile must be in -OutputDirectory*'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'leaves no folder it made, parents included, when no report is found' {
        $Root = Join-Path $script:TmpRoot 'no-report-clean'
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Stage 'readme.txt') -Value 'not a report'
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-22.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, $Zip)
        $Parent = Join-Path $Root 'new-parent'
        $Out = Join-Path $Parent 'out'
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null } | Should -Throw '*no per-subscription reports found*'
        Test-Path -LiteralPath $Parent | Should -BeFalse
    }

    It 'keeps a folder that was already there, even when it is empty' {
        $Root = Join-Path $script:TmpRoot 'no-report-kept'
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Stage 'readme.txt') -Value 'not a report'
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-23.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, $Zip)
        $Out = Join-Path $Root 'out'
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null } | Should -Throw '*no per-subscription reports found*'
        Test-Path -LiteralPath $Out -PathType Container | Should -BeTrue
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip swaps the rebuilt files in as a set, and the paths it refuses' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'puts an earlier report back whole when a later file cannot take its place' {
        $Root = Join-Path $script:TmpRoot 'swap-fail'
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        $Stamp = '20260102030405111'
        $Inner = [System.IO.Compression.ZipFile]::Open((Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
        try
        {
            # The inventory first, so it is swapped in before the html fails.
            foreach ($Pair in @(@(('Inventory_ResourcesReport_' + $Stamp + '.json'), '{"Version":"3.2.3"}'), @(('ResourcesReport_' + $Stamp + '.html'), '<html>new</html>')))
            {
                $E = $Inner.CreateEntry($Pair[0]); $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write($Pair[1]) } finally { $W.Dispose() }
            }
        }
        finally { $Inner.Dispose() }
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-30.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        $Out = Join-Path $Root 'out'
        $Dir = Join-Path $Out ('ResourcesReport_' + $Stamp)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Inv = Join-Path $Dir ('Inventory_ResourcesReport_' + $Stamp + '.json')
        Set-Content -LiteralPath $Inv -Value 'an earlier inventory' -NoNewline
        # A folder where the html goes: no file can take that place.
        New-Item -ItemType Directory -Path (Join-Path $Dir ('ResourcesReport_' + $Stamp + '.html')) -Force | Out-Null
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null } | Should -Throw
        Get-Content -LiteralPath $Inv -Raw | Should -Be 'an earlier inventory'
        @(Get-ChildItem -LiteralPath $Dir -Force | Where-Object { $_.Name -like '*.partial' -or $_.Name -like '*.bak' }) | Should -BeNullOrEmpty
    }

    It 'refuses a -PackageZip that reaches -InputZip through a linked folder, and leaves the input zip as it was' -Skip:($IsWindows) {
        $Real = Join-Path $script:TmpRoot 'link-real'
        New-Item -ItemType Directory -Path $Real -Force | Out-Null
        $InZip = Join-Path $Real 'bundle.zip'
        Copy-Item -LiteralPath $script:InputZip -Destination $InZip
        $Before = (Get-FileHash -LiteralPath $InZip).Hash
        $Alias = Join-Path $script:TmpRoot 'link-alias'
        New-Item -ItemType SymbolicLink -Path $Alias -Target $Real | Out-Null
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $InZip -OutputDirectory (Join-Path $Alias 'bundle') -PackageZip 6>$null } | Should -Throw '*which is -InputZip*'
        (Get-FileHash -LiteralPath $InZip).Hash | Should -Be $Before
        Test-Path -LiteralPath (Join-Path $Real 'bundle') | Should -BeFalse
    }

    It 'refuses a file system root as -OutputDirectory' {
        $Root = [System.IO.Path]::GetPathRoot($script:TmpRoot)
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Root 6>$null } | Should -Throw '*cannot be the root*'
    }

    It 'puts the summary in the bundle when -HtmlFile names -OutputDirectory in another letter case on a file system that ignores case' {
        # The file system here may keep case apart, so the comparer is the one
        # a case-ignoring file system gives, and the other spelling is a folder.
        Mock Get-RdaPathComparer { [System.StringComparer]::OrdinalIgnoreCase }
        $Out = Join-Path $script:TmpRoot 'casepkg'
        $Other = Join-Path $script:TmpRoot 'CASEPKG'
        New-Item -ItemType Directory -Path $Other -Force | Out-Null
        New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -HtmlFile (Join-Path $Other 'MainSummary.html') -PackageZip 6>$null | Out-Null
        Get-ZipEntryNames -ZipPath ($Out + '.zip') | Should -Contain 'MainSummary.html'
    }
}
