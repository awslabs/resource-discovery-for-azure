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
        $script:TwiceLines = @(& $script:Script -InputZip $Zip -OutputDirectory $script:TwiceOut 3>&1 6>&1 | ForEach-Object { [string]$_ })
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
        $script:TwiceFolderLines = @(& $script:Script -InputZip $Zip -OutputDirectory (Join-Path $Root 'out') 3>&1 6>&1 | ForEach-Object { [string]$_ })
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
        $script:CaseLines = @(& $script:Script -InputZip $Zip -OutputDirectory $script:CaseOut 3>&1 6>&1 | ForEach-Object { [string]$_ })
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
        Mock Out-File { Set-Content -LiteralPath $LiteralPath -Value '<html>part'; throw 'disk full' } -RemoveParameterType Encoding
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

    It 'refuses a -PackageZip that reaches -InputZip through a linked folder, and leaves the input zip as it was' {
        $Real = Join-Path $script:TmpRoot 'link-real'
        New-Item -ItemType Directory -Path $Real -Force | Out-Null
        $InZip = Join-Path $Real 'bundle.zip'
        Copy-Item -LiteralPath $script:InputZip -Destination $InZip
        $Before = (Get-FileHash -LiteralPath $InZip).Hash
        $Alias = Join-Path $script:TmpRoot 'link-alias'
        # A junction on Windows (no admin right needed), a symbolic link elsewhere.
        New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $Alias -Target $Real | Out-Null
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $InZip -OutputDirectory (Join-Path $Alias 'bundle') -PackageZip 6>$null } | Should -Throw '*which is -InputZip*'
        (Get-FileHash -LiteralPath $InZip).Hash | Should -Be $Before
        Test-Path -LiteralPath (Join-Path $Real 'bundle') | Should -BeFalse
    }

    It 'refuses an -OutputDirectory that is a link or junction to a file system root, writing nothing there' {
        $Root = [System.IO.Path]::GetPathRoot($script:TmpRoot)
        $Alias = Join-Path $script:TmpRoot ('root-alias-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $Alias -Target $Root | Out-Null
        try
        {
            { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Alias 6>$null } | Should -Throw '*cannot be the root*'
            # Where links cannot be followed (PowerShell 7.0/7.1), the link stops it too.
            $Saved = $script:RdaCanResolveLinks
            $script:RdaCanResolveLinks = $false
            try { { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Alias 6>$null } | Should -Throw '*cannot follow*' }
            finally { $script:RdaCanResolveLinks = $Saved }
        }
        finally { [System.IO.Directory]::Delete($Alias) }
        Test-Path -LiteralPath (Join-Path $Root 'MainSummary.html') | Should -BeFalse
    }

    It 'refuses a file system root as -OutputDirectory' {
        $Root = [System.IO.Path]::GetPathRoot($script:TmpRoot)
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Root 6>$null } | Should -Throw '*cannot be the root*'
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip puts files back when the swap fails, is stopped, or a file cannot be put back' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
        # An input zip with one report (inventory first, then html), and a
        # reused output folder for it; returns the paths the tests need.
        function script:New-SwapCase
        {
            param([string]$Name, [string]$Stamp, [switch]$NoEarlierInventory, [switch]$HtmlIsFolder)
            $Root = Join-Path $script:TmpRoot $Name
            $Stage = Join-Path $Root 'outer'
            New-Item -ItemType Directory -Path $Stage -Force | Out-Null
            $Inner = [System.IO.Compression.ZipFile]::Open((Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
            try
            {
                foreach ($Pair in @(@(('Inventory_ResourcesReport_' + $Stamp + '.json'), '{"Version":"3.2.3"}'), @(('ResourcesReport_' + $Stamp + '.html'), '<html>new</html>')))
                {
                    $E = $Inner.CreateEntry($Pair[0]); $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write($Pair[1]) } finally { $W.Dispose() }
                }
            }
            finally { $Inner.Dispose() }
            $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-40.zip'
            Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
            $Out = Join-Path $Root 'out'
            $Dir = Join-Path $Out ('ResourcesReport_' + $Stamp)
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $Inv = Join-Path $Dir ('Inventory_ResourcesReport_' + $Stamp + '.json')
            $Html = Join-Path $Dir ('ResourcesReport_' + $Stamp + '.html')
            if (-not $NoEarlierInventory) { Set-Content -LiteralPath $Inv -Value 'an earlier inventory' -NoNewline }
            if ($HtmlIsFolder) { New-Item -ItemType Directory -Path $Html -Force | Out-Null }
            else { Set-Content -LiteralPath $Html -Value 'an earlier html' -NoNewline }
            [pscustomobject]@{ Zip = $Zip; Out = $Out; Dir = $Dir; Inv = $Inv; Html = $Html }
        }
    }

    It 'removes a file that was new when a later file cannot take its place' {
        $C = New-SwapCase -Name 'swap-new' -Stamp '20260102030405121' -NoEarlierInventory -HtmlIsFolder
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $C.Zip -OutputDirectory $C.Out 6>$null } | Should -Throw
        Test-Path -LiteralPath $C.Inv | Should -BeFalse
        @(Get-ChildItem -LiteralPath $C.Dir -Force | Where-Object { $_.Name -like '*.partial' -or $_.Name -like '*.bak' }) | Should -BeNullOrEmpty
    }

    It 'puts back every file it can when one cannot be put back, and names the one kept aside' {
        $C = New-SwapCase -Name 'swap-restore-fail' -Stamp '20260102030405122'
        # The html cannot take its place, and the old inventory cannot be put back.
        Mock Move-RdaFile {
            if ($Path -like '*.partial' -and $Destination -like '*.html') { throw 'html is locked' }
            if ($Path -like '*.bak' -and $Destination -like '*.json') { throw 'inventory is locked' }
            [System.IO.File]::Move($Path, $Destination, [bool]$Overwrite)
        }
        $Err = $null
        try { New-RdaAllSubHtmlSummaryFromZip -InputZip $C.Zip -OutputDirectory $C.Out 6>$null } catch { $Err = $_.Exception.Message }
        $Err | Should -BeLike '*html is locked*'
        $Bak = @(Get-ChildItem -LiteralPath $C.Dir -Filter '*.json.rda-*.bak')
        $Bak.Count | Should -Be 1
        Get-Content -LiteralPath $Bak[0].FullName -Raw | Should -Be 'an earlier inventory'
        $Err | Should -BeLike ('*' + $Bak[0].FullName + ' is the earlier file; ' + $C.Inv + ' now holds the new one: replace it with the earlier file*')
        Test-Path -LiteralPath $C.Inv | Should -BeTrue
        Get-Content -LiteralPath $C.Html -Raw | Should -Be 'an earlier html'
    }

    It 'puts the earlier files back when the run is stopped while they take their places' {
        $C = New-SwapCase -Name 'swap-stop' -Stamp '20260102030405123'
        $Flag = Join-Path $script:TmpRoot 'swap-stop.flag'
        $Ps = [powershell]::Create()
        try
        {
            $null = $Ps.AddScript({
                    param($Functions, $Zip, $Out, $Flag)
                    . $Functions
                    $script:HoldFlag = $Flag
                    # Holds the html's move, so the stop lands mid-swap.
                    function Move-RdaFile
                    {
                        param($Path, $Destination, [switch]$Overwrite)
                        if ($Path -like '*.partial' -and $Destination -like '*.html') { New-Item -ItemType File -Path $script:HoldFlag | Out-Null; Start-Sleep -Seconds 60 }
                        [System.IO.File]::Move($Path, $Destination, [bool]$Overwrite)
                    }
                    New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null
                }).AddArgument((Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')).AddArgument($C.Zip).AddArgument($C.Out).AddArgument($Flag)
            $Handle = $Ps.BeginInvoke()
            $Until = [datetime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath $Flag) -and [datetime]::UtcNow -lt $Until -and -not $Handle.IsCompleted) { Start-Sleep -Milliseconds 100 }
            Test-Path -LiteralPath $Flag | Should -BeTrue -Because 'the swap reached the html'
            $Ps.Stop()
        }
        finally { $Ps.Dispose() }
        Get-Content -LiteralPath $C.Inv -Raw | Should -Be 'an earlier inventory'
        Get-Content -LiteralPath $C.Html -Raw | Should -Be 'an earlier html'
        @(Get-ChildItem -LiteralPath $C.Dir -Force | Where-Object { $_.Name -like '*.partial' -or $_.Name -like '*.bak' }) | Should -BeNullOrEmpty
    }
}

Describe 'Get-RdaPhysicalPath and the root check' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'follows a link whose target goes through another linked folder' -Skip:($IsWindows) {
        $Base = Join-Path $script:TmpRoot 'phys'
        $Data = Join-Path $Base 'data'
        New-Item -ItemType Directory -Path (Join-Path $Data 'sub') -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $Base 'a') -Target $Data | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $Base 'l') -Target (Join-Path $Base 'a/sub') | Out-Null
        $Real = [System.IO.DirectoryInfo]::new((Join-Path $Data 'sub')).FullName
        Get-RdaPhysicalPath -Path (Join-Path $Base 'l/file.zip') | Should -Be (Join-Path (Get-RdaPhysicalPath -Path $Real) 'file.zip')
        Get-RdaPhysicalPath -Path (Join-Path $Base 'l/file.zip') | Should -Not -BeLike '*/a/*'
    }

    It 'refuses a share root given with its separator' -Skip:(-not $IsWindows) {
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory '\\localhost\C$\' 6>$null } | Should -Throw '*cannot be the root*'
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip and links, rooted entries, and files it cannot remove' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
        # A zip whose entries are the given names and texts, in order.
        function script:New-EntryZip
        {
            param([string]$Path, [object[]]$Pairs)
            $Zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
            try { foreach ($Pair in $Pairs) { $E = $Zip.CreateEntry($Pair[0]); $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write($Pair[1]) } finally { $W.Dispose() } } }
            finally { $Zip.Dispose() }
            $Path
        }
        # A consolidated zip holding one report zip of the given entries.
        function script:New-OneReportZip
        {
            param([string]$Root, [string]$Stamp, [object[]]$Pairs)
            $Stage = Join-Path $Root 'outer'
            New-Item -ItemType Directory -Path $Stage -Force | Out-Null
            $null = New-EntryZip -Path (Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')) -Pairs $Pairs
            $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-50.zip'
            Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
            $Zip
        }
        $script:LinkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    }

    It 'stops -PackageZip on a path with a link where this PowerShell cannot follow links, and leaves the input zip as it was' {
        $Real = Join-Path $script:TmpRoot 'nolinkapi-real'
        New-Item -ItemType Directory -Path $Real -Force | Out-Null
        $InZip = Join-Path $Real 'bundle.zip'
        Copy-Item -LiteralPath $script:InputZip -Destination $InZip
        $Before = (Get-FileHash -LiteralPath $InZip).Hash
        $Alias = Join-Path $script:TmpRoot 'nolinkapi-alias'
        New-Item -ItemType $script:LinkType -Path $Alias -Target $Real | Out-Null
        $Saved = $script:RdaCanResolveLinks
        $script:RdaCanResolveLinks = $false
        try { { New-RdaAllSubHtmlSummaryFromZip -InputZip $InZip -OutputDirectory (Join-Path $Alias 'bundle') -PackageZip 6>$null } | Should -Throw '*cannot follow*' }
        finally { $script:RdaCanResolveLinks = $Saved }
        (Get-FileHash -LiteralPath $InZip).Hash | Should -Be $Before
    }

    It 'stops before writing when a report folder in -OutputDirectory is a link (<Kind>)' -ForEach @(@{ Kind = 'report zip' }, @{ Kind = 'extracted folder' }) {
        $Root = Join-Path $script:TmpRoot ('report-link-' + ($Kind -replace ' ', '-'))
        $Stamp = '20260102030405131'
        $Pairs = @(@(('Inventory_ResourcesReport_' + $Stamp + '.json'), '{"Version":"3.2.3"}'), @(('ResourcesReport_' + $Stamp + '.html'), '<html>new</html>'))
        if ($Kind -eq 'report zip') { $Zip = New-OneReportZip -Root $Root -Stamp $Stamp -Pairs $Pairs }
        else
        {
            $Src = Join-Path $Root ('outer/ResourcesReport_' + $Stamp)
            New-Item -ItemType Directory -Path $Src -Force | Out-Null
            foreach ($Pair in $Pairs) { Set-Content -LiteralPath (Join-Path $Src $Pair[0]) -Value $Pair[1] }
            $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-51.zip'
            [System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $Root 'outer'), $Zip)
        }
        $Outside = Join-Path $Root 'outside'
        New-Item -ItemType Directory -Path $Outside -Force | Out-Null
        $OutsideInv = Join-Path $Outside ('Inventory_ResourcesReport_' + $Stamp + '.json')
        Set-Content -LiteralPath $OutsideInv -Value 'not in the output folder' -NoNewline
        $Out = Join-Path $Root 'out'
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        New-Item -ItemType $script:LinkType -Path (Join-Path $Out ('ResourcesReport_' + $Stamp)) -Target $Outside | Out-Null
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null } | Should -Throw '*is a link or junction*'
        Get-Content -LiteralPath $OutsideInv -Raw | Should -Be 'not in the output folder'
        @(Get-ChildItem -LiteralPath $Outside -Force).Count | Should -Be 1
    }

    It 'refuses a zip entry rooted on any system (<Name>)' -ForEach @(@{ Name = '\evil.txt' }, @{ Name = '\\server\share\evil.txt' }, @{ Name = '/evil.txt' }, @{ Name = 'C:evil.txt' }) {
        $Path = New-EntryZip -Path (Join-Path $script:TmpRoot ('rooted-' + [guid]::NewGuid().ToString('N') + '.zip')) -Pairs @(, @($Name, 'x'))
        { Assert-RdaZipWithinLimit -Path $Path } | Should -Throw '*rooted or .. path*'
    }

    It 'names a new file it could not remove when putting files back' {
        $Root = Join-Path $script:TmpRoot 'undo-remove-fail'
        $Stamp = '20260102030405132'
        $Zip = New-OneReportZip -Root $Root -Stamp $Stamp -Pairs @(@(('Inventory_ResourcesReport_' + $Stamp + '.json'), '{"Version":"3.2.3"}'), @(('ResourcesReport_' + $Stamp + '.html'), '<html>new</html>'))
        $Out = Join-Path $Root 'out'
        $Dir = Join-Path $Out ('ResourcesReport_' + $Stamp)
        # No earlier inventory, and a folder where the html goes.
        New-Item -ItemType Directory -Path (Join-Path $Dir ('ResourcesReport_' + $Stamp + '.html')) -Force | Out-Null
        $Inv = Join-Path $Dir ('Inventory_ResourcesReport_' + $Stamp + '.json')
        Mock Remove-Item { throw 'inventory is locked' } -ParameterFilter { $LiteralPath -eq $Inv }
        $Err = $null
        try { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null } catch { $Err = $_.Exception.Message }
        $Err | Should -BeLike ('*' + $Inv + ' is a new file that could not be removed: delete it*')
    }

    It 'names only the earlier file when a target written twice cannot be put back' {
        $Root = Join-Path $script:TmpRoot 'undo-twice'
        $Stamp = '20260102030405133'
        $InvName = 'Inventory_ResourcesReport_' + $Stamp + '.json'
        $Zip = New-OneReportZip -Root $Root -Stamp $Stamp -Pairs @(@(('a/' + $InvName), '{"Version":"3.2.3"}'), @(('b/' + $InvName), '{"Version":"3.2.3"}'), @(('ResourcesReport_' + $Stamp + '.html'), '<html>new</html>'))
        $Out = Join-Path $Root 'out'
        $Dir = Join-Path $Out ('ResourcesReport_' + $Stamp)
        New-Item -ItemType Directory -Path (Join-Path $Dir ('ResourcesReport_' + $Stamp + '.html')) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Dir $InvName) -Value 'an earlier inventory' -NoNewline
        Mock Move-RdaFile {
            if ($Path -like '*.bak') { throw 'locked' }
            [System.IO.File]::Move($Path, $Destination, [bool]$Overwrite)
        }
        $Err = $null
        try { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null } catch { $Err = $_.Exception.Message }
        $Bak = @(Get-ChildItem -LiteralPath $Dir -Filter '*.bak')
        $Bak.Count | Should -Be 1
        Get-Content -LiteralPath $Bak[0].FullName -Raw | Should -Be 'an earlier inventory'
        ([regex]::Matches($Err, 'is the earlier file')).Count | Should -Be 1
        $Err | Should -BeLike ('*' + $Bak[0].FullName + ' is the earlier file*')
    }

    It 'warns, naming it, when the staging folder cannot be removed' {
        Mock Remove-Item { throw 'staging is busy' } -ParameterFilter { $LiteralPath -like '*RdaFromZip_*' }
        $Out = Join-Path $script:TmpRoot 'staging-warn'
        $null = New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -WarningVariable Warn -WarningAction SilentlyContinue 6>$null
        $Line = @($Warn | Where-Object { "$_" -like 'Could not remove*RdaFromZip_*staging is busy*' })
        $Line.Count | Should -Be 1
        # Tidy the folder the mock kept.
        $Kept = [regex]::Match("$($Line[0])", 'Could not remove (.+?): ').Groups[1].Value
        if ($Kept -and (Test-Path -LiteralPath $Kept)) { [System.IO.Directory]::Delete($Kept, $true) }
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip with reparse folders that are not links, a rendered html name, and one warning a leftover' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
        function script:New-InvOnlyZip
        {
            param([string]$Root, [string]$Stamp, [switch]$WithHtml)
            $Stage = Join-Path $Root 'outer'
            New-Item -ItemType Directory -Path $Stage -Force | Out-Null
            $Zip = [System.IO.Compression.ZipFile]::Open((Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
            try
            {
                $Pairs = @(, @(('Inventory_ResourcesReport_' + $Stamp + '.json'), '{"Version":"3.2.3","PublicIP":[{"Name":"pip","Subscription":"Sub"}]}'))
                if ($WithHtml) { $Pairs += , @(('ResourcesReport_' + $Stamp + '.html'), '<html>new</html>') }
                foreach ($Pair in $Pairs) { $E = $Zip.CreateEntry($Pair[0]); $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write($Pair[1]) } finally { $W.Dispose() } }
            }
            finally { $Zip.Dispose() }
            $Outer = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-60.zip'
            Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Outer -Force
            $Outer
        }
        # A copy of the functions beside a stand-in renderer.
        function script:Use-StandInRenderer
        {
            param([string]$Tree, [string]$Body)
            New-Item -ItemType Directory -Path (Join-Path $Tree 'Functions'), (Join-Path $Tree 'Extension') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') -Destination (Join-Path $Tree 'Functions')
            Set-Content -LiteralPath (Join-Path $Tree 'Extension/Summary.ps1') -Value ('param($JsonFile, $HtmlFile, $Title, $Version, $PlatOS) ' + $Body)
            Join-Path $Tree 'Functions/AllSubHtmlSummary.Functions.ps1'
        }
    }
    AfterAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'rebuilds into a report folder that is a reparse point but not a link (a OneDrive folder)' {
        $Root = Join-Path $script:TmpRoot 'onedrive-like'
        $Stamp = '20260102030405141'
        $Zip = New-InvOnlyZip -Root $Root -Stamp $Stamp -WithHtml
        $Out = Join-Path $Root 'out'
        $Dest = Join-Path $Out ('ResourcesReport_' + $Stamp)
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
        Mock Get-Item { [pscustomobject]@{ Attributes = [System.IO.FileAttributes]'Directory, ReparsePoint'; LinkType = $null } } -ParameterFilter { $LiteralPath -eq $Dest -and $Force }
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out -KeepOriginalReports 6>$null } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $Dest ('Inventory_ResourcesReport_' + $Stamp + '.json')) | Should -BeTrue
    }

    It 'stops on a report folder that is a dangling link' -Skip:($IsWindows) {
        $Root = Join-Path $script:TmpRoot 'dangling'
        $Stamp = '20260102030405142'
        $Zip = New-InvOnlyZip -Root $Root -Stamp $Stamp -WithHtml
        $Out = Join-Path $Root 'out'
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $Out ('ResourcesReport_' + $Stamp)) -Target (Join-Path $Root 'gone') | Out-Null
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null } | Should -Throw '*is a link or junction*'
    }

    It 'never links or bundles an html already in the folder when the render of a report without one fails' {
        . (Use-StandInRenderer -Tree (Join-Path $script:TmpRoot 'render-fail-tree') -Body 'throw "renderer failed"')
        $Root = Join-Path $script:TmpRoot 'stale-html-fail'
        $Stamp = '20260102030405143'
        $Zip = New-InvOnlyZip -Root $Root -Stamp $Stamp
        $Out = Join-Path $Root 'out'
        $Stale = Join-Path $Out ('ResourcesReport_' + $Stamp + '/ResourcesReport_' + $Stamp + '.html')
        New-Item -ItemType Directory -Path (Split-Path $Stale -Parent) -Force | Out-Null
        Set-Content -LiteralPath $Stale -Value '<html>stale</html>' -NoNewline
        $Said = New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out -PackageZip 6>&1 | Out-String
        $Said | Should -BeLike '*Re-render skipped for ResourcesReport_*(no html for this report)*'
        Get-Content -LiteralPath $Stale -Raw | Should -Be '<html>stale</html>'
        Get-ZipEntryNames -ZipPath ($Out + '.zip') | Should -Not -Contain ('ResourcesReport_' + $Stamp + '/ResourcesReport_' + $Stamp + '.html')
        Get-Content -LiteralPath (Join-Path $Out 'MainSummary.html') -Raw | Should -Not -BeLike ('*ResourcesReport_' + $Stamp + '.html*')
    }

    It 'renders a report without an html under its folder name, replacing one already there, and keeps one html when run again' {
        . (Use-StandInRenderer -Tree (Join-Path $script:TmpRoot 'render-ok-tree') -Body 'Set-Content -LiteralPath $HtmlFile -Value "<html>rendered</html>" -NoNewline')
        $Root = Join-Path $script:TmpRoot 'stale-html-ok'
        $Stamp = '20260102030405144'
        $Zip = New-InvOnlyZip -Root $Root -Stamp $Stamp
        $Out = Join-Path $Root 'out'
        $Dir = Join-Path $Out ('ResourcesReport_' + $Stamp)
        $Html = Join-Path $Dir ('ResourcesReport_' + $Stamp + '.html')
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Set-Content -LiteralPath $Html -Value '<html>stale</html>' -NoNewline
        foreach ($Run in 1..2) { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out -PackageZip 6>$null | Out-Null }
        Get-Content -LiteralPath $Html -Raw | Should -Be '<html>rendered</html>'
        @(Get-ChildItem -LiteralPath $Dir -Force | Where-Object { $_.Name -like '*.html*' }).Name | Should -Be @('ResourcesReport_' + $Stamp + '.html')
        Get-ZipEntryNames -ZipPath ($Out + '.zip') | Should -Contain ('ResourcesReport_' + $Stamp + '/ResourcesReport_' + $Stamp + '.html')
    }

    It 'puts the earlier html back when the rendered one cannot take its place' {
        . (Use-StandInRenderer -Tree (Join-Path $script:TmpRoot 'render-move-tree') -Body 'Set-Content -LiteralPath $HtmlFile -Value "<html>rendered</html>" -NoNewline')
        $Root = Join-Path $script:TmpRoot 'stale-html-move'
        $Stamp = '20260102030405146'
        $Zip = New-InvOnlyZip -Root $Root -Stamp $Stamp
        $Out = Join-Path $Root 'out'
        $Dir = Join-Path $Out ('ResourcesReport_' + $Stamp)
        $Html = Join-Path $Dir ('ResourcesReport_' + $Stamp + '.html')
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Set-Content -LiteralPath $Html -Value '<html>stale</html>' -NoNewline
        Mock Move-RdaFile { if ($Path -like '*.html.rda-*.partial') { throw 'locked' }; [System.IO.File]::Move($Path, $Destination, [bool]$Overwrite) }
        New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null | Out-Null
        Get-Content -LiteralPath $Html -Raw | Should -Be '<html>stale</html>'
        @(Get-ChildItem -LiteralPath $Dir -Force | Where-Object { $_.Name -like '*.bak' -or $_.Name -like '*.partial' }) | Should -BeNullOrEmpty
        Get-Content -LiteralPath (Join-Path $Out 'MainSummary.html') -Raw | Should -Not -BeLike ('*ResourcesReport_' + $Stamp + '.html*')
    }

    It 'warns once about a private file it cannot remove after a failed swap' {
        $Root = Join-Path $script:TmpRoot 'partial-warn-once'
        $Stamp = '20260102030405145'
        $Zip = New-InvOnlyZip -Root $Root -Stamp $Stamp -WithHtml
        $Out = Join-Path $Root 'out'
        $Dir = Join-Path $Out ('ResourcesReport_' + $Stamp)
        New-Item -ItemType Directory -Path (Join-Path $Dir ('ResourcesReport_' + $Stamp + '.html')) -Force | Out-Null
        Mock Remove-Item { throw 'busy' } -ParameterFilter { $LiteralPath -like '*.partial' }
        $Threw = $false
        try { New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out -WarningVariable Warn -WarningAction SilentlyContinue 6>$null } catch { $Threw = $true }
        $Threw | Should -BeTrue
        $Lines = @($Warn | Where-Object { "$_" -like 'Could not remove*.partial*' })
        $Lines.Count | Should -Be 1
        Get-ChildItem -LiteralPath $Dir -Filter '*.partial' | ForEach-Object { [System.IO.File]::Delete($_.FullName) }
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip render swap on a stop, and the budget with -KeepOriginalReports' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'puts the earlier html back when the run is stopped while the rendered one takes its place' {
        $Tree = Join-Path $script:TmpRoot 'render-stop-tree'
        New-Item -ItemType Directory -Path (Join-Path $Tree 'Functions'), (Join-Path $Tree 'Extension') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') -Destination (Join-Path $Tree 'Functions')
        Set-Content -LiteralPath (Join-Path $Tree 'Extension/Summary.ps1') -Value 'param($JsonFile, $HtmlFile, $Title, $Version, $PlatOS) Set-Content -LiteralPath $HtmlFile -Value "<html>rendered</html>" -NoNewline'
        $Root = Join-Path $script:TmpRoot 'render-stop'
        $Stamp = '20260102030405151'
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        $Zip = [System.IO.Compression.ZipFile]::Open((Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
        try { $E = $Zip.CreateEntry('Inventory_ResourcesReport_' + $Stamp + '.json'); $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write('{"Version":"3.2.3"}') } finally { $W.Dispose() } } finally { $Zip.Dispose() }
        $Outer = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-70.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Outer -Force
        $Out = Join-Path $Root 'out'
        $Dir = Join-Path $Out ('ResourcesReport_' + $Stamp)
        $Html = Join-Path $Dir ('ResourcesReport_' + $Stamp + '.html')
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Set-Content -LiteralPath $Html -Value '<html>stale</html>' -NoNewline
        $Flag = Join-Path $script:TmpRoot 'render-stop.flag'
        $Ps = [powershell]::Create()
        try
        {
            $null = $Ps.AddScript({
                    param($Functions, $Zip, $Out, $Flag)
                    . $Functions
                    $script:HoldFlag = $Flag
                    # Holds the render's move in, after the earlier html is moved aside.
                    function Move-RdaFile
                    {
                        param($Path, $Destination, [switch]$Overwrite)
                        if ($Path -like '*.html.rda-*.partial') { New-Item -ItemType File -Path $script:HoldFlag | Out-Null; Start-Sleep -Seconds 60 }
                        [System.IO.File]::Move($Path, $Destination, [bool]$Overwrite)
                    }
                    New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null
                }).AddArgument((Join-Path $Tree 'Functions/AllSubHtmlSummary.Functions.ps1')).AddArgument($Outer).AddArgument($Out).AddArgument($Flag)
            $Handle = $Ps.BeginInvoke()
            $Until = [datetime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath $Flag) -and [datetime]::UtcNow -lt $Until -and -not $Handle.IsCompleted) { Start-Sleep -Milliseconds 100 }
            Test-Path -LiteralPath $Flag | Should -BeTrue -Because 'the render reached its move in'
            $Ps.Stop()
        }
        finally { $Ps.Dispose() }
        Get-Content -LiteralPath $Html -Raw | Should -Be '<html>stale</html>'
        @(Get-ChildItem -LiteralPath $Dir -Force | Where-Object { $_.Name -like '*.partial' -or $_.Name -like '*.bak' }) | Should -BeNullOrEmpty
    }

    It 'does not count an html it will not render with -KeepOriginalReports (<Kind>)' -ForEach @(@{ Kind = 'report zips' }, @{ Kind = 'extracted folders' }) {
        $Root = Join-Path $script:TmpRoot ('keep-budget-' + ($Kind -replace ' ', '-'))
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        # 1000 inventory-only reports and the summary: 1001 files to write.
        foreach ($N in 1..1000)
        {
            $Stamp = '2026010205{0:D7}' -f $N
            $Name = 'Inventory_ResourcesReport_' + $Stamp + '.json'
            if ($Kind -eq 'report zips')
            {
                $Zip = [System.IO.Compression.ZipFile]::Open((Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
                try { $E = $Zip.CreateEntry($Name); $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write('{"Version":"3.2.3"}') } finally { $W.Dispose() } } finally { $Zip.Dispose() }
            }
            else
            {
                $Dir = Join-Path $Stage ('ResourcesReport_' + $Stamp)
                New-Item -ItemType Directory -Path $Dir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $Dir $Name) -Value '{"Version":"3.2.3"}'
            }
        }
        $Outer = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-71.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, $Outer)
        $Out = Join-Path $Root 'out'
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer -OutputDirectory $Out -KeepOriginalReports 6>$null } | Should -Not -Throw
        @(Get-ChildItem -LiteralPath $Out -Recurse -File).Count | Should -Be 1001
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip with case-variant names, a renderer path with brackets, and the skipped-render line' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
        function script:New-PairsZip
        {
            param([string]$Root, [string]$Stamp, [object[]]$Pairs)
            $Stage = Join-Path $Root 'outer'
            [void][System.IO.Directory]::CreateDirectory($Stage)
            $Zip = [System.IO.Compression.ZipFile]::Open((Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
            try { foreach ($Pair in $Pairs) { $E = $Zip.CreateEntry($Pair[0]); $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write($Pair[1]) } finally { $W.Dispose() } } }
            finally { $Zip.Dispose() }
            $Outer = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-80.zip'
            [System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, $Outer)
            $Outer
        }
    }
    AfterAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'bundles a file once when two entry names differ only in case on a file system that ignores case' {
        # This host may keep case apart, so the comparer is the one a
        # case-ignoring file system gives.
        Mock Get-RdaPathComparer { [System.StringComparer]::OrdinalIgnoreCase }
        $Root = Join-Path $script:TmpRoot 'case-entries'
        $Stamp = '20260102030405161'
        $Zip = New-PairsZip -Root $Root -Stamp $Stamp -Pairs @(@(('Inventory_ResourcesReport_' + $Stamp + '.json'), '{"Version":"3.2.3"}'), @(('ResourcesReport_' + $Stamp + '.html'), '<html>a</html>'), @(('resourcesreport_' + $Stamp + '.html'), '<html>b</html>'))
        $Out = Join-Path $Root 'out'
        New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out -PackageZip -KeepOriginalReports 6>$null | Out-Null
        $Names = @(Get-ZipEntryNames -ZipPath ($Out + '.zip') | ForEach-Object { $_.ToLowerInvariant() })
        $Names.Count | Should -Be @($Names | Select-Object -Unique).Count
    }

    It 'finds the renderer when the repo folder name holds brackets' {
        $Tree = Join-Path $script:TmpRoot 'rda[2]'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $Tree 'Functions'))
        [void][System.IO.Directory]::CreateDirectory((Join-Path $Tree 'Extension'))
        [System.IO.File]::Copy((Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1'), (Join-Path $Tree 'Functions/AllSubHtmlSummary.Functions.ps1'), $true)
        [System.IO.File]::WriteAllText((Join-Path $Tree 'Extension/Summary.ps1'), 'param($JsonFile, $HtmlFile, $Title, $Version, $PlatOS) [System.IO.File]::WriteAllText($HtmlFile, "<html>rendered</html>")')
        . (Join-Path $Tree 'Functions/AllSubHtmlSummary.Functions.ps1')
        $Root = Join-Path $script:TmpRoot 'bracket-render'
        $Stamp = '20260102030405162'
        $Zip = New-PairsZip -Root $Root -Stamp $Stamp -Pairs @(@(('Inventory_ResourcesReport_' + $Stamp + '.json'), '{"Version":"3.2.3"}'), @(('ResourcesReport_' + $Stamp + '.html'), '<html>original</html>'))
        $Out = Join-Path $Root 'out'
        New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out 6>$null | Out-Null
        [System.IO.File]::ReadAllText((Join-Path $Out ('ResourcesReport_' + $Stamp + '/ResourcesReport_' + $Stamp + '.html'))) | Should -Be '<html>rendered</html>'
    }

    It 'does not say "kept original" when the earlier html could not be put back' {
        $Root = Join-Path $script:TmpRoot 'label-not-in-place'
        $Stamp = '20260102030405163'
        $Zip = New-PairsZip -Root $Root -Stamp $Stamp -Pairs @(@(('Inventory_ResourcesReport_' + $Stamp + '.json'), '{"Version":"3.2.3","PublicIP":[{"Name":"pip","Subscription":"Sub"}]}'), @(('ResourcesReport_' + $Stamp + '.html'), '<html>original</html>'))
        $Out = Join-Path $Root 'out'
        # The render cannot move in (the second html move in; the first is the
        # html from the zip), and the html moved aside cannot be put back.
        $script:HtmlMovesIn = 0
        Mock Move-RdaFile {
            if ($Path -like '*.html.rda-*.partial' -and $Destination -like '*.html' -and ++$script:HtmlMovesIn -eq 2) { throw 'locked' }
            if ($Path -like '*.html.rda-*.bak') { throw 'locked too' }
            [System.IO.File]::Move($Path, $Destination, [bool]$Overwrite)
        }
        $Said = New-RdaAllSubHtmlSummaryFromZip -InputZip $Zip -OutputDirectory $Out -WarningAction SilentlyContinue 6>&1 | Out-String
        $Said | Should -BeLike '*Re-render skipped for ResourcesReport_*(the earlier html is not in place; see the warning)*'
        $Said | Should -Not -BeLike '*kept original*'
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip with a report folder that compares case apart from its parent, and an output folder with brackets' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'names both earlier files when a report folder keeps case apart under an output folder that ignores it' {
        $Root = Join-Path $script:TmpRoot 'child-case'
        $Stamp = '20260102030405171'
        $Stage = Join-Path $Root 'outer'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        $InvName = 'Inventory_ResourcesReport_' + $Stamp + '.json'
        $Zip = [System.IO.Compression.ZipFile]::Open((Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
        try { foreach ($Pair in @(@('A.html', '<html>new A</html>'), @('a.html', '<html>new a</html>'), @($InvName, '{"Version":"3.2.3"}'))) { $E = $Zip.CreateEntry($Pair[0]); $W = [System.IO.StreamWriter]::new($E.Open()); try { $W.Write($Pair[1]) } finally { $W.Dispose() } } }
        finally { $Zip.Dispose() }
        $Outer = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-90.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, $Outer)
        $Out = Join-Path $Root 'out'
        $Dir = Join-Path $Out ('ResourcesReport_' + $Stamp)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Dir 'A.html') -Value 'earlier A' -NoNewline
        Set-Content -LiteralPath (Join-Path $Dir 'a.html') -Value 'earlier a' -NoNewline
        # A folder where the inventory goes, so the swap fails after both html.
        New-Item -ItemType Directory -Path (Join-Path $Dir $InvName) -Force | Out-Null
        # -OutputDirectory ignores case; the report folder keeps it apart.
        Mock Get-RdaPathComparer { [System.StringComparer]::Ordinal }
        Mock Get-RdaPathComparer { [System.StringComparer]::OrdinalIgnoreCase } -ParameterFilter { $Path.TrimEnd('/', '\') -eq $Out }
        Mock Move-RdaFile { if ($Path -like '*.bak') { throw 'locked' }; [System.IO.File]::Move($Path, $Destination, [bool]$Overwrite) }
        $Err = $null
        try { New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer -OutputDirectory $Out -KeepOriginalReports 6>$null } catch { $Err = $_.Exception.Message }
        ([regex]::Matches([string]$Err, 'is the earlier file')).Count | Should -Be 2
        $Kept = @(Get-ChildItem -LiteralPath $Dir -Filter '*.bak' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw } | Sort-Object)
        $Kept | Should -Be @('earlier A', 'earlier a' | Sort-Object)
    }

    It 'writes the main summary and re-renders when -OutputDirectory sits under a folder with brackets' {
        $Out = Join-Path (Join-Path $script:TmpRoot 'out[1]') 'rebuilt'
        New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out 6>$null | Out-Null
        Test-Path -LiteralPath (Join-Path $Out 'MainSummary.html') -PathType Leaf | Should -BeTrue
        $Said = New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out 6>&1 | Out-String
        $Said | Should -Not -BeLike '*Re-render skipped*'
    }
}

Describe 'New-RdaAllSubHtmlSummary -ReportFiles by folder and file name, and the renderer''s file size under brackets' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'keeps a report whose folder is named in another letter case where the run folder ignores case and the report folder keeps it' {
        $Run = Join-Path $script:TmpRoot 'allowed-leaf'
        $Dir = Join-Path $Run 'ResourcesReport_20260102030405181'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Inv = Join-Path $Dir 'Inventory_ResourcesReport_20260102030405181.json'
        '{"Version":"3.2.3","PublicIP":[{"Name":"pip","Subscription":"Sub"}]}' | Set-Content -LiteralPath $Inv
        Mock Get-RdaPathComparer { [System.StringComparer]::Ordinal }
        Mock Get-RdaPathComparer { [System.StringComparer]::OrdinalIgnoreCase } -ParameterFilter { $Path.TrimEnd('/', '\') -eq $Run }
        # The folder part of the listed path in another case.
        $Listed = Join-Path (Join-Path $Run 'resourcesreport_20260102030405181') 'Inventory_ResourcesReport_20260102030405181.json'
        $Said = New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile (Join-Path $Run 'MainSummary.html') -ReportFiles @($Listed) 6>&1 | Out-String
        $Said | Should -BeLike '*1 subscription(s)*'
    }

    It 'reports the html file size when -HtmlFile sits in a folder with brackets' {
        $Dir = Join-Path $script:TmpRoot 'size[1]'
        [void][System.IO.Directory]::CreateDirectory($Dir)
        $Json = Join-Path $Dir 'Inventory_x.json'
        [System.IO.File]::WriteAllText($Json, '{"Version":"3.2.3","PublicIP":[{"Name":"pip","Subscription":"Sub"}]}')
        $Said = & (Join-Path $script:RepoRoot 'Extension/Summary.ps1') -JsonFile $Json -HtmlFile (Join-Path $Dir 'r.html') -Title 'T' 6>&1 2>&1 | Out-String
        $Size = [System.IO.FileInfo]::new((Join-Path $Dir 'r.html')).Length
        $Size | Should -BeGreaterThan 0
        $Said | Should -BeLike ('*File size: {0:N0} bytes*' -f $Size)
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip under strict mode, and the real scripts from a repo folder with brackets' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'rebuilds into a new folder under Set-StrictMode -Version Latest (<Case>)' -ForEach @(@{ Case = 'links followed' }, @{ Case = 'links not followable' }) {
        # The temp folder as followed (it can sit under a link, such as /var on
        # macOS), so a PowerShell that cannot follow links finds none in it.
        $Base = Get-RdaPhysicalPath -Path $script:TmpRoot
        $InZip = Join-Path $Base ('strict-in-' + ($Case -replace ' ', '-') + '.zip')
        Copy-Item -LiteralPath $script:InputZip -Destination $InZip
        $Out = Join-Path $Base ('strict-' + ($Case -replace ' ', '-'))
        $Saved = $script:RdaCanResolveLinks
        if ($Case -eq 'links not followable') { $script:RdaCanResolveLinks = $false }
        try
        {
            Set-StrictMode -Version Latest
            $Said = New-RdaAllSubHtmlSummaryFromZip -InputZip $InZip -OutputDirectory $Out -PackageZip 6>&1 | Out-String
        }
        finally { Set-StrictMode -Off; $script:RdaCanResolveLinks = $Saved }
        Test-Path -LiteralPath ($Out + '.zip') -PathType Leaf | Should -BeTrue
        # The renderer runs under strict mode too.
        $Said | Should -Not -BeLike '*Re-render skipped*'
    }

    It 'runs Build-MainSummaryFromZip.ps1 and the real renderer from a repo folder with brackets' {
        $Tree = Join-Path $script:TmpRoot 'repo[3]'
        [void][System.IO.Directory]::CreateDirectory($Tree)
        foreach ($Part in 'Build-MainSummaryFromZip.ps1', 'Extension', 'Functions', 'Version.json')
        {
            $From = Join-Path $script:RepoRoot $Part
            if (Test-Path -LiteralPath $From) { Copy-Item -LiteralPath $From -Destination (Join-Path $Tree $Part) -Recurse -Force }
        }
        $Out = Join-Path $script:TmpRoot 'repo-bracket-out'
        $Said = & (Join-Path $Tree 'Build-MainSummaryFromZip.ps1') -InputZip $script:InputZip -OutputDirectory $Out 6>&1 2>&1 | Out-String
        Test-Path -LiteralPath (Join-Path $Out 'MainSummary.html') -PathType Leaf | Should -BeTrue
        $Said | Should -Not -BeLike '*Re-render skipped*'
        $Said | Should -Not -BeLike '*not found*'
    }
}

Describe 'New-RdaAllSubHtmlSummary with an inventory that cannot be read' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'still links the report html' {
        $Run = Join-Path $script:TmpRoot 'unreadable-link'
        $Dir = Join-Path $Run 'ResourcesReport_20260102030405191'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Dir 'Inventory_ResourcesReport_20260102030405191.json') -Value '{ not json'
        Set-Content -LiteralPath (Join-Path $Dir 'ResourcesReport_20260102030405191.html') -Value '<html>report</html>'
        $Html = Join-Path $Run 'MainSummary.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Html 6>$null | Out-Null
        Get-Content -LiteralPath $Html -Raw | Should -Match 'href="ResourcesReport_20260102030405191[\\/]ResourcesReport_20260102030405191\.html"'
    }
}

Describe 'Extension/Summary.ps1 service type count' {
    It 'counts one service type for an inventory that holds one service' {
        $Dir = Join-Path $script:TmpRoot 'one-service'
        [void][System.IO.Directory]::CreateDirectory($Dir)
        $Json = Join-Path $Dir 'Inventory_one.json'
        [System.IO.File]::WriteAllText($Json, '{"Version":"3.2.3","PublicIP":[{"Name":"a","Subscription":"S"},{"Name":"b","Subscription":"S"},{"Name":"c","Subscription":"S"}]}')
        $Html = Join-Path $Dir 'r.html'
        & (Join-Path $script:RepoRoot 'Extension/Summary.ps1') -JsonFile $Json -HtmlFile $Html -Title 'T' 6>$null | Out-Null
        [System.IO.File]::ReadAllText($Html) | Should -Match '<b>Service Types:</b> 1</div>'
    }
}

Describe 'Totals of 0 under strict mode' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1') }

    It 'renders a report with no resources with a total of 0' {
        $Dir = Join-Path $script:TmpRoot 'zero-total'
        [void][System.IO.Directory]::CreateDirectory($Dir)
        $Json = Join-Path $Dir 'Inventory_zero.json'
        [System.IO.File]::WriteAllText($Json, '{"Version":"3.2.3","PublicIP":[]}')
        $Html = Join-Path $Dir 'r.html'
        try { Set-StrictMode -Version Latest; & (Join-Path $script:RepoRoot 'Extension/Summary.ps1') -JsonFile $Json -HtmlFile $Html -Title 'T' 6>$null | Out-Null }
        finally { Set-StrictMode -Off }
        [System.IO.File]::ReadAllText($Html) | Should -Match '<b>Total Resources:</b> 0</div>'
    }

    It 'renders the main summary of a run folder with no reports' {
        $Run = Join-Path $script:TmpRoot 'no-reports-strict'
        [void][System.IO.Directory]::CreateDirectory($Run)
        $Html = Join-Path $Run 'MainSummary.html'
        try { Set-StrictMode -Version Latest; { New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Html 6>$null } | Should -Not -Throw }
        finally { Set-StrictMode -Off }
        [System.IO.File]::ReadAllText($Html) | Should -BeLike '*No per-subscription reports*'
    }
}

Describe 'Extension/Summary.ps1 privacy wording in a re-rendered report' {
    It 'never says a report is suitable for sharing from a sample of masked names' {
        $Dir = Join-Path $script:TmpRoot 'privacy-sample'
        [void][System.IO.Directory]::CreateDirectory($Dir)
        $Json = Join-Path $Dir 'Inventory_masked.json'
        $Rows = foreach ($N in 1..4) { '{{"Name":"prod_{0}","Subscription":"prod_{1}"}}' -f [guid]::NewGuid(), [guid]::NewGuid() }
        [System.IO.File]::WriteAllText($Json, ('{"Version":"3.2.3","PublicIP":[' + ($Rows -join ',') + ']}'))
        $Html = Join-Path $Dir 'r.html'
        $Said = & (Join-Path $script:RepoRoot 'Extension/Summary.ps1') -JsonFile $Json -HtmlFile $Html -Title 'T' 6>&1 | Out-String
        $Text = [System.IO.File]::ReadAllText($Html)
        $Text | Should -Not -BeLike '*Suitable for sharing*'
        $Text | Should -BeLike '*review the report before sharing it*'
        $Said | Should -Not -BeLike '*(safe to share)*'
    }
}

Describe 'Extension/Summary.ps1 reads a consumption file in a folder with brackets' {
    It 'runs the VM billing check on it' {
        $Dir = Join-Path $script:TmpRoot 'con[1]'
        [void][System.IO.Directory]::CreateDirectory($Dir)
        $Json = Join-Path $Dir 'Inventory_vms.json'
        $Vms = foreach ($N in 1..3) { '{{"Name":"vm{0}","Subscription":"S","PowerState":"vm running"}}' -f $N }
        [System.IO.File]::WriteAllText($Json, ('{"Version":"3.2.3","VirtualMachines":[' + ($Vms -join ',') + ']}'))
        $Csv = Join-Path $Dir 'Consumption_vms.csv'
        [System.IO.File]::WriteAllLines($Csv, [string[]]@('MeterCategory,ResourceId', '"Virtual Machines","/x/vm1"'))
        $Html = Join-Path $Dir 'r.html'
        & (Join-Path $script:RepoRoot 'Extension/Summary.ps1') -JsonFile $Json -HtmlFile $Html -Title 'T' -ConsumptionFile $Csv 6>$null | Out-Null
        [System.IO.File]::ReadAllText($Html) | Should -Match 'VM billing-coverage check'
    }

    It 'counts a VM whose state is transient or empty as running in the VM billing check, as pricing does' {
        $Dir = Join-Path $script:TmpRoot 'vm-states'
        [void][System.IO.Directory]::CreateDirectory($Dir)
        $Json = Join-Path $Dir 'Inventory_vms.json'
        $Vms = @('{"Name":"vm1","Subscription":"S","PowerState":"vm running"}', '{"Name":"vm2","Subscription":"S","PowerState":"vm starting (transient)"}', '{"Name":"vm3","Subscription":"S","PowerState":""}', '{"Name":"vm4","Subscription":"S"}')
        [System.IO.File]::WriteAllText($Json, ('{"Version":"3.2.3","VirtualMachines":[' + ($Vms -join ',') + ']}'))
        $Csv = Join-Path $Dir 'Consumption_vms.csv'
        [System.IO.File]::WriteAllLines($Csv, [string[]]@('MeterCategory,ResourceId', '"Virtual Machines","/x/vm1"'))
        $Html = Join-Path $Dir 'r.html'
        & (Join-Path $script:RepoRoot 'Extension/Summary.ps1') -JsonFile $Json -HtmlFile $Html -Title 'T' -ConsumptionFile $Csv 6>$null | Out-Null
        [System.IO.File]::ReadAllText($Html) | Should -Match 'VM billing-coverage check'
    }
}

Describe 'New-RdaAllSubHtmlSummaryFromZip with two rebuilds into one folder at once' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
    }

    It 'refuses the second rebuild while the first is moving its files in, and the first finishes whole' {
        $Out = Join-Path $script:TmpRoot 'two-at-once'
        $script:Nested = $null
        $script:NestedRan = $false
        # The second rebuild starts while the first moves its first file in.
        Mock Move-RdaFile {
            if (-not $script:NestedRan)
            {
                $script:NestedRan = $true
                try { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -KeepOriginalReports 6>$null | Out-Null }
                catch { $script:Nested = $_.Exception.Message }
            }
            [System.IO.File]::Move($Path, $Destination, [bool]$Overwrite)
        }
        New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -KeepOriginalReports 6>$null | Out-Null
        $script:NestedRan | Should -BeTrue
        $script:Nested | Should -BeLike '*another rebuild is writing into*'
        foreach ($Stamp in $script:Stamps)
        {
            $Base = 'ResourcesReport_' + $Stamp
            Test-Path -LiteralPath (Join-Path $Out ('{0}/{0}.html' -f $Base)) | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Out ('{0}/Inventory_{0}.json' -f $Base)) | Should -BeTrue
        }
        # No private file is left (the lock file is not one: it stays).
        @(Get-ChildItem -LiteralPath $Out -Recurse -Force | Where-Object { $_.Name -like '*.rda-*' -and $_.Name -ne '.rda-rebuild.lock' }) | Should -BeNullOrEmpty
    }

    It 'is refused while another caller holds the lock file in the folder itself, whatever its user or temp folder' {
        $Out = Join-Path $script:TmpRoot 'held-in-folder'
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Out 'kept.txt') -Value 'mine' -NoNewline
        $Held = [System.IO.File]::Open((Join-Path $Out '.rda-rebuild.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try
        {
            { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -KeepOriginalReports 6>$null } | Should -Throw '*another rebuild is writing into*'
        }
        finally { $Held.Dispose() }
        @(Get-ChildItem -LiteralPath $Out -Force | Where-Object { $_.Name -ne '.rda-rebuild.lock' } | ForEach-Object { $_.Name }) | Should -Be @('kept.txt')
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -KeepOriginalReports 6>$null } | Should -Not -Throw
    }

    It 'keeps the lock file in the folder after a rebuild, unlocked and out of the bundle, so a caller that opened it is never given a removed file' {
        $Out = Join-Path $script:TmpRoot 'lock-kept'
        New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -KeepOriginalReports -PackageZip 6>$null | Out-Null
        $Lock = Join-Path $Out '.rda-rebuild.lock'
        Test-Path -LiteralPath $Lock | Should -BeTrue
        $Open = [System.IO.File]::Open($Lock, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $Open.Dispose()
        @(Get-ZipEntryNames -ZipPath ($Out + '.zip') | Where-Object { $_ -like '*rda-rebuild*' }) | Should -BeNullOrEmpty
    }

    It 'removes the lock file of a folder it made while it still holds the lock (Linux and macOS)' -Skip:($IsWindows) {
        $Out = Join-Path $script:TmpRoot 'held-while-removed'
        $script:HeldAtRemoval = $null
        Mock Move-RdaFile { throw 'disk full' }
        Mock Clear-RdaLeftover -ParameterFilter { $Path -like '*.rda-rebuild.lock' } -MockWith {
            # Another caller tries to take the lock now: it must still be held.
            try { $Probe = [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None); $Probe.Dispose(); $script:HeldAtRemoval = $false }
            catch { $script:HeldAtRemoval = $true }
            Remove-Item -LiteralPath $Path -Force
        }
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -KeepOriginalReports 6>$null } | Should -Throw '*disk full*'
        $script:HeldAtRemoval | Should -BeTrue
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'removes a folder it made, lock file included, when the rebuild fails' {
        $Out = Join-Path $script:TmpRoot 'made-then-failed'
        Mock Move-RdaFile { throw 'disk full' }
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -KeepOriginalReports 6>$null } | Should -Throw '*disk full*'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'removes the folders it made when the lock cannot be taken for another reason' -Skip:($IsWindows -or [Environment]::UserName -eq 'root') {
        $Parent = Join-Path $script:TmpRoot 'lock-fails-in-made'
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
        $Out = Join-Path $Parent 'new'
        Mock Lock-RdaOutputDirectory { throw 'New-RdaAllSubHtmlSummaryFromZip: could not take the rebuild lock x: stand-in' }
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -KeepOriginalReports 6>$null } | Should -Throw '*could not take the rebuild lock*'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'names the real cause, not another rebuild, when the lock cannot be taken for another reason' -Skip:($IsWindows -or [Environment]::UserName -eq 'root') {
        $Out = Join-Path $script:TmpRoot 'not-writable'
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        & chmod 555 $Out
        try
        {
            $Message = $null
            try { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -KeepOriginalReports 6>$null | Out-Null } catch { $Message = $_.Exception.Message }
            $Message | Should -BeLike '*could not take the rebuild lock*'
            $Message | Should -Not -BeLike '*another rebuild*'
        }
        finally { & chmod 755 $Out }
    }

    It 'lets the next rebuild in after one that failed part-way' {
        $Out = Join-Path $script:TmpRoot 'after-a-failure'
        Mock Move-RdaFile { throw 'disk full' }
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -KeepOriginalReports 6>$null } | Should -Throw '*disk full*'
        Mock Move-RdaFile { [System.IO.File]::Move($Path, $Destination, [bool]$Overwrite) }
        { New-RdaAllSubHtmlSummaryFromZip -InputZip $script:InputZip -OutputDirectory $Out -KeepOriginalReports 6>$null } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $Out 'MainSummary.html') | Should -BeTrue
    }
}
