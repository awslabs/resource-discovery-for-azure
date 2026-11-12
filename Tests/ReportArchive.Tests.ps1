# Compress-RdaReportArchive tests
# =============================================================================
# ResourceInventory.ps1 zips the report with Compress-RdaReportArchive, which
# streams each file into a new archive. Compress-Archive (Microsoft.PowerShell.
# Archive 1.2.x) opens its archive in Update mode, which holds every entry's
# uncompressed bytes in memory until the archive is closed.
#
# Compress-Archive is the reference here: for the same -Path list (the default
# run's list with its *.json wildcard, and the -Obfuscate filtered list) both
# must produce the same entries - names, order, count, content bytes and
# timestamps - at the same compression level. The failure tests check that no
# zip is left at the final name and no temporary file stays behind, and that an
# existing destination is an error that leaves that file untouched.
#
# Offline and self-contained: every file is generated under $TestDrive; the
# only GUID is the Azure docs placeholder.
# =============================================================================

BeforeAll {
    $FunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1'
    if (-not (Test-Path $FunctionsFile)) { throw "ResourceInventory.Functions.ps1 not found at $FunctionsFile" }
    . $FunctionsFile

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.ZipFile

    $script:FixedTime = [datetime]::new(2026, 1, 2, 3, 4, 6)
    $script:Sep = [System.IO.Path]::DirectorySeparatorChar

    function Write-FixtureFile
    {
        param([string]$Path, [string]$Content, [datetime]$LastWriteTime = $script:FixedTime)
        [System.IO.File]::WriteAllText($Path, $Content)
        [System.IO.File]::SetLastWriteTime($Path, $LastWriteTime)
    }

    # Deterministic, compressible JSON of roughly the shape the collectors write.
    function Get-JsonText
    {
        param([int]$Records, [int]$Seed)
        $Builder = [System.Text.StringBuilder]::new()
        [void]$Builder.Append('{"Metrics":[')
        for ($i = 0; $i -lt $Records; $i++)
        {
            if ($i -gt 0) { [void]$Builder.Append(',') }
            [void]$Builder.AppendFormat('{{"Id":"/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-{0}/providers/Microsoft.Compute/disks/disk-{1}","Metric":"Composite Disk Read Bytes/sec","Value":{2}}}', (($i + $Seed) % 17), $i, ((($i + $Seed) * 7919) % 100003))
        }
        [void]$Builder.Append(']}')
        return $Builder.ToString()
    }

    # A report folder with the files a run leaves behind, plus the edge cases
    # the *.json wildcard can meet: a hidden file, a directory whose name
    # matches, an empty file and a pre-1980 timestamp.
    function Initialize-ReportFolder
    {
        param([string]$Root)
        New-Item -ItemType Directory -Path $Root | Out-Null
        $Name = 'ResourcesReport_2026-01-02_03_04'
        Write-FixtureFile (Join-Path $Root "$Name.html") ('<html><body>' + ('<p>report</p>' * 500) + '</body></html>')
        Write-FixtureFile (Join-Path $Root "Consumption_$Name.csv") ("InstanceData,MeterCategory`n" + ('a,b' + "`n") * 300)
        Write-FixtureFile (Join-Path $Root "Diagnostics_$Name.log") 'Phase timings:'
        Write-FixtureFile (Join-Path $Root "Inventory_$Name.json") (Get-JsonText -Records 3000 -Seed 1)
        Write-FixtureFile (Join-Path $Root "Metrics_$Name.json") (Get-JsonText -Records 2000 -Seed 2)
        Write-FixtureFile (Join-Path $Root "Metrics_${Name}_2.json") (Get-JsonText -Records 1500 -Seed 3)
        Write-FixtureFile (Join-Path $Root "Full_$Name.json") (Get-JsonText -Records 100 -Seed 4)
        Write-FixtureFile (Join-Path $Root "ObfuscationDictionary_$Name.json") '{"ResourceIdMap":{}}'
        Write-FixtureFile (Join-Path $Root "Heartbeat_$Name.json") '{"Phase":"Done"}'
        Write-FixtureFile (Join-Path $Root "DebugLog_$Name.json") '[]'
        Write-FixtureFile (Join-Path $Root "ErrorLog_$Name.json") '[]'
        Write-FixtureFile (Join-Path $Root "Empty_$Name.json") ''
        Write-FixtureFile (Join-Path $Root "Old_$Name.json") '{"Old":true}' -LastWriteTime ([datetime]::new(1975, 6, 1))
        Write-FixtureFile (Join-Path $Root "PowerShell_Transcript_$Name.txt") 'transcript'
        $Hidden = Join-Path $Root ".hidden_$Name.json"
        Write-FixtureFile $Hidden '{"Hidden":true}'
        if ($IsWindows) { [System.IO.File]::SetAttributes($Hidden, [System.IO.FileAttributes]::Hidden) }
        $Folder = Join-Path $Root 'Folder.json'
        New-Item -ItemType Directory -Path (Join-Path $Folder 'EmptySub') -Force | Out-Null
        Write-FixtureFile (Join-Path $Folder 'inner.txt') 'inner'
    }

    # One row per entry, in archive order. An empty-folder entry has no source
    # file, so both tools stamp it with the time of archiving; that time is not
    # compared.
    function Get-ZipEntrySummary
    {
        param([string]$ZipPath)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try
        {
            foreach ($Entry in $Archive.Entries)
            {
                $Stream = $Entry.Open()
                try { $Hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Stream)) } finally { $Stream.Dispose() }
                [pscustomobject]@{
                    Name          = $Entry.FullName
                    Length        = $Entry.Length
                    Sha256        = $Hash
                    LastWriteTime = $(if ($Entry.FullName.EndsWith('/')) { 'archive time' } else { $Entry.LastWriteTime.ToString('o') })
                }
            }
        }
        finally
        {
            $Archive.Dispose()
        }
    }

    # Compression method, general-purpose flags (bits 1-2 carry the deflate
    # level) and compressed size of each entry, read from the central directory.
    function Get-ZipCentralDirectory
    {
        param([string]$ZipPath)
        $Bytes = [System.IO.File]::ReadAllBytes($ZipPath)
        $Eocd = $Bytes.Length - 22
        while ($Eocd -ge 0 -and [System.BitConverter]::ToUInt32($Bytes, $Eocd) -ne 0x06054b50) { $Eocd-- }
        if ($Eocd -lt 0) { throw "No end of central directory record in $ZipPath" }
        $Count = [System.BitConverter]::ToUInt16($Bytes, $Eocd + 10)
        $Offset = [int][System.BitConverter]::ToUInt32($Bytes, $Eocd + 16)
        for ($i = 0; $i -lt $Count; $i++)
        {
            $NameLength = [System.BitConverter]::ToUInt16($Bytes, $Offset + 28)
            [pscustomobject]@{
                Name           = [System.Text.Encoding]::UTF8.GetString($Bytes, $Offset + 46, $NameLength)
                Flags          = [System.BitConverter]::ToUInt16($Bytes, $Offset + 8)
                Method         = [System.BitConverter]::ToUInt16($Bytes, $Offset + 10)
                CompressedSize = [System.BitConverter]::ToUInt32($Bytes, $Offset + 20)
            }
            $Offset += 46 + $NameLength + [System.BitConverter]::ToUInt16($Bytes, $Offset + 30) + [System.BitConverter]::ToUInt16($Bytes, $Offset + 32)
        }
    }

    function ConvertTo-Comparable
    {
        param($Rows)
        return (@($Rows) | ConvertTo-Json -Compress -Depth 3)
    }

    function Get-FolderListing
    {
        param([string]$Root)
        return @(Get-ChildItem -LiteralPath $Root -Force | ForEach-Object { '{0}|{1}' -f $_.Name, $(if ($_.PSIsContainer) { 'dir' } else { $_.Length }) }) -join "`n"
    }

    $script:ReportDir = Join-Path $TestDrive 'report'
    Initialize-ReportFolder -Root $script:ReportDir
    $script:ReportName = 'ResourcesReport_2026-01-02_03_04'
    $script:DefaultPath = $script:ReportDir + $script:Sep
    $script:HtmlFile = $script:DefaultPath + $script:ReportName + '.html'
    $script:ConsumptionFile = $script:DefaultPath + 'Consumption_' + $script:ReportName + '.csv'
    $script:DiagnosticsFile = $script:DefaultPath + 'Diagnostics_' + $script:ReportName + '.log'

    # Same Path lists ResourceInventory.ps1 builds for a default and an -Obfuscate run.
    $script:DefaultRunPaths = @($script:HtmlFile, $script:ConsumptionFile, ($script:DefaultPath + '*.json')) + @($script:DiagnosticsFile)
    $JsonFiles = Get-ChildItem -Path $script:DefaultPath -Filter '*.json' | Where-Object { $_.Name -notlike 'ObfuscationDictionary_*' -and $_.Name -notlike 'Full_*' -and $_.Name -notlike 'Heartbeat_*' -and $_.Name -notlike 'DebugLog_*' -and $_.Name -notlike 'ErrorLog_*' } | Select-Object -ExpandProperty FullName
    $script:ObfuscateRunPaths = @($script:HtmlFile, $script:ConsumptionFile) + @($script:DiagnosticsFile) + $JsonFiles
}

Describe 'Compress-RdaReportArchive produces the same archive as Compress-Archive' {
    It 'for the default run Path list (HTML, consumption CSV, *.json wildcard, diagnostics log)' {
        $Expected = Join-Path $script:ReportDir 'expected-default.zip'
        $Actual = Join-Path $script:ReportDir 'actual-default.zip'
        Compress-Archive -Path $script:DefaultRunPaths -CompressionLevel Fastest -DestinationPath $Expected -WarningAction SilentlyContinue
        Compress-RdaReportArchive -Path $script:DefaultRunPaths -CompressionLevel Fastest -DestinationPath $Actual -WarningAction SilentlyContinue

        $ExpectedRows = @(Get-ZipEntrySummary $Expected)
        $ActualRows = @(Get-ZipEntrySummary $Actual)
        # The fixture reaches the edge cases: a matching directory is stored
        # with its contents, the hidden file is not, and pre-1980 is clamped.
        $ExpectedRows.Name | Should -Contain 'Folder.json/EmptySub/'
        $ExpectedRows.Name | Should -Contain 'Folder.json/inner.txt'
        $ExpectedRows.Name | Should -Not -Contain ".hidden_$($script:ReportName).json"
        ($ExpectedRows | Where-Object Name -EQ "Old_$($script:ReportName).json").LastWriteTime | Should -BeLike '1980-01-01T00:00:00*'

        $ActualRows.Count | Should -Be $ExpectedRows.Count
        $ActualRows.Name | Should -Be $ExpectedRows.Name
        (ConvertTo-Comparable $ActualRows) | Should -Be (ConvertTo-Comparable $ExpectedRows)
    }

    It 'for the -Obfuscate run Path list (explicit, filtered JSON list)' {
        $Expected = Join-Path $script:ReportDir 'expected-obfuscate.zip'
        $Actual = Join-Path $script:ReportDir 'actual-obfuscate.zip'
        Compress-Archive -Path $script:ObfuscateRunPaths -CompressionLevel Fastest -DestinationPath $Expected -WarningAction SilentlyContinue
        Compress-RdaReportArchive -Path $script:ObfuscateRunPaths -CompressionLevel Fastest -DestinationPath $Actual -WarningAction SilentlyContinue

        $ExpectedRows = @(Get-ZipEntrySummary $Expected)
        $ActualRows = @(Get-ZipEntrySummary $Actual)
        $ExpectedRows.Name | Should -Not -Contain "ObfuscationDictionary_$($script:ReportName).json"
        $ActualRows.Count | Should -Be $ExpectedRows.Count
        $ActualRows.Name | Should -Be $ExpectedRows.Name
        (ConvertTo-Comparable $ActualRows) | Should -Be (ConvertTo-Comparable $ExpectedRows)
    }

    It 'at the same compression level' {
        $Fastest = Join-Path $script:ReportDir 'level-fastest.zip'
        $Optimal = Join-Path $script:ReportDir 'level-optimal.zip'
        $Actual = Join-Path $script:ReportDir 'level-actual.zip'
        Compress-Archive -Path $script:DefaultRunPaths -CompressionLevel Fastest -DestinationPath $Fastest -WarningAction SilentlyContinue
        Compress-Archive -Path $script:DefaultRunPaths -CompressionLevel Optimal -DestinationPath $Optimal -WarningAction SilentlyContinue
        Compress-RdaReportArchive -Path $script:DefaultRunPaths -CompressionLevel Fastest -DestinationPath $Actual -WarningAction SilentlyContinue

        $FastestRows = @(Get-ZipCentralDirectory $Fastest)
        $ActualRows = @(Get-ZipCentralDirectory $Actual)
        (ConvertTo-Comparable $ActualRows) | Should -Be (ConvertTo-Comparable $FastestRows)

        # The comparison can tell levels apart: Optimal stores the inventory smaller.
        $InventoryName = "Inventory_$($script:ReportName).json"
        $OptimalSize = (@(Get-ZipCentralDirectory $Optimal) | Where-Object Name -EQ $InventoryName).CompressedSize
        ($ActualRows | Where-Object Name -EQ $InventoryName).CompressedSize | Should -BeGreaterThan $OptimalSize
    }

    It 'stores a file twice when the wildcard and an explicit path both match it' {
        $Inventory = $script:DefaultPath + "Inventory_$($script:ReportName).json"
        $Paths = @(($script:DefaultPath + 'Metrics_*.json'), ($script:DefaultPath + 'Inventory_*.json'), $Inventory)
        $Expected = Join-Path $script:ReportDir 'expected-twice.zip'
        $Actual = Join-Path $script:ReportDir 'actual-twice.zip'
        Compress-Archive -Path $Paths -CompressionLevel Fastest -DestinationPath $Expected
        Compress-RdaReportArchive -Path $Paths -CompressionLevel Fastest -DestinationPath $Actual

        $ExpectedRows = @(Get-ZipEntrySummary $Expected)
        @($ExpectedRows | Where-Object Name -EQ "Inventory_$($script:ReportName).json").Count | Should -Be 2
        (ConvertTo-Comparable (Get-ZipEntrySummary $Actual)) | Should -Be (ConvertTo-Comparable $ExpectedRows)
    }

    It 'rejects the same path string listed twice and writes nothing' {
        $Paths = @($script:HtmlFile, $script:HtmlFile)
        $Expected = Join-Path $script:ReportDir 'expected-duplicate.zip'
        $Actual = Join-Path $script:ReportDir 'actual-duplicate.zip'
        { Compress-Archive -Path $Paths -DestinationPath $Expected } | Should -Throw
        { Compress-RdaReportArchive -Path $Paths -DestinationPath $Actual } | Should -Throw '*duplicate path*'
        Test-Path -LiteralPath $Expected | Should -BeFalse
        Test-Path -LiteralPath $Actual | Should -BeFalse
    }

    It 'writes no zip when there is nothing to store' {
        $Root = Join-Path $TestDrive 'nothing'
        New-Item -ItemType Directory -Path (Join-Path $Root 'Empty.json') -Force | Out-Null
        $Expected = Join-Path $Root 'expected.zip'
        $Actual = Join-Path $Root 'actual.zip'
        Compress-Archive -Path (Join-Path $Root '*.json') -DestinationPath $Expected
        Compress-RdaReportArchive -Path (Join-Path $Root '*.json') -DestinationPath $Actual
        Test-Path -LiteralPath $Expected | Should -BeFalse
        Test-Path -LiteralPath $Actual | Should -BeFalse
        @(Get-ChildItem -LiteralPath $Root -Force).Name | Should -Be @('Empty.json')
    }
}

Describe 'Compress-RdaReportArchive failure handling' {
    It 'leaves no zip at the final name and no temporary file when it fails part-way' {
        $Root = Join-Path $TestDrive 'failing'
        New-Item -ItemType Directory -Path $Root | Out-Null
        Write-FixtureFile (Join-Path $Root 'a.json') (Get-JsonText -Records 2000 -Seed 8)
        Write-FixtureFile (Join-Path $Root 'b.json') (Get-JsonText -Records 2000 -Seed 9)
        $Locked = Join-Path $Root 'z.json'
        Write-FixtureFile $Locked '{}'
        $Paths = @((Join-Path $Root 'a.json'), (Join-Path $Root 'b.json'), $Locked)
        $Before = Get-FolderListing $Root

        # z.json is held open without sharing, so it cannot be read after
        # a.json and b.json have been written to the archive.
        $Hold = [System.IO.File]::Open($Locked, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try
        {
            $Reference = Join-Path $Root 'reference.zip'
            { Compress-Archive -Path $Paths -DestinationPath $Reference 2>$null } | Should -Throw
            Test-Path -LiteralPath $Reference | Should -BeFalse

            # Called the way ResourceInventory.ps1 calls it: inside try/catch,
            # with the default run's SilentlyContinue error preference.
            $Destination = Join-Path $Root 'report.zip'
            $Caught = & {
                $ErrorActionPreference = 'SilentlyContinue'
                try
                {
                    Compress-RdaReportArchive -Path $Paths -CompressionLevel Fastest -DestinationPath $Destination
                    'not caught'
                }
                catch
                {
                    $_.Exception.Message
                }
            }
        }
        finally
        {
            $Hold.Dispose()
        }
        $Caught | Should -BeLike '*z.json*'
        Test-Path -LiteralPath $Destination | Should -BeFalse
        Get-FolderListing $Root | Should -Be $Before
    }

    It 'fails when the destination already exists and leaves that file untouched' {
        $Root = Join-Path $TestDrive 'exists'
        New-Item -ItemType Directory -Path $Root | Out-Null
        Write-FixtureFile (Join-Path $Root 'a.json') (Get-JsonText -Records 20 -Seed 10)
        $Destination = Join-Path $Root 'report.zip'
        [System.IO.File]::WriteAllBytes($Destination, [byte[]](1, 2, 3, 4))
        $Before = Get-FolderListing $Root

        { Compress-Archive -Path (Join-Path $Root 'a.json') -DestinationPath $Destination } | Should -Throw '*already exists*'

        $Caught = & {
            $ErrorActionPreference = 'SilentlyContinue'
            try
            {
                Compress-RdaReportArchive -Path (Join-Path $Root 'a.json') -CompressionLevel Fastest -DestinationPath $Destination
                'not caught'
            }
            catch
            {
                $_.Exception.Message
            }
        }
        $Caught | Should -BeLike '*already exists*'
        [System.IO.File]::ReadAllBytes($Destination) | Should -Be @(1, 2, 3, 4)
        Get-FolderListing $Root | Should -Be $Before
    }
}

Describe 'Compress-RdaReportArchive with a long destination file name' {
    # Most Linux and Windows file systems allow 255 characters per file name.
    # The temporary file must fit wherever the final name fits.
    BeforeAll {
        function Get-LongZipName
        {
            param([int]$Length)
            $Prefix = 'ResourcesReport_2026-01-02_03_04_'
            return $Prefix + ('x' * ($Length - $Prefix.Length - 4)) + '.zip'
        }
    }

    It 'writes a zip whose file name is <Length> characters' -ForEach @(@{ Length = 223 }, @{ Length = 250 }) {
        $Root = Join-Path $TestDrive "long-$Length"
        New-Item -ItemType Directory -Path $Root | Out-Null
        Write-FixtureFile (Join-Path $Root 'a.json') (Get-JsonText -Records 200 -Seed 11)
        Write-FixtureFile (Join-Path $Root 'b.json') (Get-JsonText -Records 100 -Seed 12)
        $Name = Get-LongZipName -Length $Length
        $Name.Length | Should -Be $Length
        $Destination = Join-Path $Root $Name

        Compress-RdaReportArchive -Path (Join-Path $Root '*.json') -CompressionLevel Fastest -DestinationPath $Destination

        Test-Path -LiteralPath $Destination -PathType Leaf | Should -BeTrue
        $Rows = @(Get-ZipEntrySummary $Destination)
        $Rows.Name | Should -Be @('a.json', 'b.json')
        foreach ($Row in $Rows)
        {
            $Row.Sha256 | Should -Be (Get-FileHash -LiteralPath (Join-Path $Root $Row.Name) -Algorithm SHA256).Hash
        }
        @(Get-ChildItem -LiteralPath $Root -Force).Name | Sort-Object | Should -Be (@('a.json', 'b.json', $Name) | Sort-Object)
    }

    It 'leaves no zip at the final name and no temporary file when it fails part-way with a 250-character name' {
        $Root = Join-Path $TestDrive 'long-failing'
        New-Item -ItemType Directory -Path $Root | Out-Null
        Write-FixtureFile (Join-Path $Root 'a.json') (Get-JsonText -Records 2000 -Seed 13)
        $Locked = Join-Path $Root 'z.json'
        Write-FixtureFile $Locked '{}'
        $Paths = @((Join-Path $Root 'a.json'), $Locked)
        $Before = Get-FolderListing $Root
        $Destination = Join-Path $Root (Get-LongZipName -Length 250)

        # z.json is held open without sharing, so the failure comes after
        # a.json has been written to the temporary archive.
        $Hold = [System.IO.File]::Open($Locked, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try
        {
            $Caught = & {
                $ErrorActionPreference = 'SilentlyContinue'
                try
                {
                    Compress-RdaReportArchive -Path $Paths -CompressionLevel Fastest -DestinationPath $Destination
                    'not caught'
                }
                catch
                {
                    $_.Exception.Message
                }
            }
        }
        finally
        {
            $Hold.Dispose()
        }
        $Caught | Should -BeLike '*z.json*'
        Test-Path -LiteralPath $Destination | Should -BeFalse
        Get-FolderListing $Root | Should -Be $Before
    }
}

Describe 'ResourceInventory.ps1 report packaging' {
    It 'zips the report with Compress-RdaReportArchive, not Compress-Archive' {
        $ScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $Commands = @($Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.CommandAst] }, $true))
        @($Commands | Where-Object { $_.GetCommandName() -eq 'Compress-Archive' }).Count | Should -Be 0
        $Calls = @($Commands | Where-Object { $_.GetCommandName() -eq 'Compress-RdaReportArchive' })
        $Calls.Count | Should -Be 1
        $Calls[0].Extent.Text | Should -Be 'Compress-RdaReportArchive @CompressionOutput -ErrorAction Stop'
    }
}
