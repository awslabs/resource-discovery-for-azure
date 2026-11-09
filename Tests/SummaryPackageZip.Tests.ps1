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
    function Get-SummaryLinks
    {
        param([Parameter(Mandatory)][string]$HtmlPath)
        $Html = Get-Content -LiteralPath $HtmlPath -Raw
        @([regex]::Matches($Html, 'href="([^"]+\.html)"') | ForEach-Object { $_.Groups[1].Value.Replace('\', '/') } | Sort-Object)
    }

    # The links a summary of these stamps holds, one per reconstructed folder.
    function Get-ExpectedLinks
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
        Get-SummaryLinks -HtmlPath $Summary | Should -Be (Get-ExpectedLinks -Stamps $script:Stamps)
        $Html = Get-Content -LiteralPath $Summary -Raw
        $Html | Should -Not -Match 'Wrapper Subscription' -Because 'the wrapper folder is not in the input zip'
        $Html | Should -Not -Match 'ResourcesReport_?20251201' -Because 'neither earlier folder is in the input zip'
    }

    It 'keeps every packaged summary link resolvable after extraction' {
        $Links = @(Get-SummaryLinks -HtmlPath (Join-Path $script:ReusedExtract 'MainSummary.html'))
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
            Get-SummaryLinks -HtmlPath (Join-Path $script:ObfExtract 'MainSummary.html') | Should -Be (Get-ExpectedLinks -Stamps $script:ObfStamps)
        }

        It 'keeps every packaged summary link resolvable after extraction' {
            $Links = @(Get-SummaryLinks -HtmlPath (Join-Path $script:ObfExtract 'MainSummary.html'))
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

        & $script:Script -InputZip $script:InputZip -OutputDirectory $script:Same -PackageZip 6>$null | Out-Null
        $script:SamePackage = $script:Same + '.zip'
        $script:SameEntries = if (Test-Path -LiteralPath $script:SamePackage) { Get-ZipEntryNames -ZipPath $script:SamePackage } else { @() }
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
