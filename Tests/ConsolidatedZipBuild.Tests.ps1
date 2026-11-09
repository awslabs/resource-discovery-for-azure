# Run-AllSubscriptions.ps1: the consolidated zip
#
# The wrapper ends by putting every per-subscription report zip of the run into
# AllSubscriptions_ResourcesReport_<timestamp>.zip, then adds RunSummary.log and
# MainSummary.html to it. When either write fails (a full disk, or a report zip
# another process holds open), Compress-Archive removes the zip. These tests check
# that the run then says so, does not print the zip's path as written, and ends
# with exit code 2, and that the path is printed only after the last check.
#
# The bundling block, the fold block, the check after it, the banner and the
# exit-code statements are taken from the wrapper's parsed source and run as written. The wrapper itself
# cannot run here (it needs a signed-in Azure session). Compress-Archive is real,
# except where a test says it is mocked.
#
# Run with: Invoke-Pester ./Tests/ConsolidatedZipBuild.Tests.ps1 -Output Detailed

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:FunctionsPath = Join-Path $RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1'
    . $script:FunctionsPath
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $Tokens = $null
    $ParseErrors = $null
    $script:WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)

    # The one top-level 'if (<Condition>)' statement of the wrapper whose text contains $Contains.
    function script:Find-WrapperIf
    {
        param([string]$Condition, [string]$Contains)
        $Found = @($script:WrapperAst.EndBlock.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.IfStatementAst] -and
                $_.Clauses[0].Item1.Extent.Text -eq $Condition -and
                $_.Extent.Text.Contains($Contains)
            })
        if ($Found.Count -ne 1)
        {
            throw ("expected exactly one top-level 'if ({0})' containing '{1}' in Run-AllSubscriptions.ps1, found {2}" -f $Condition, $Contains, $Found.Count)
        }
        $Found[0]
    }

    # One per-subscription report folder with its zip, the way ResourceInventory.ps1 leaves it.
    function script:New-SubReport
    {
        param([string]$Root, [string]$Stamp)
        $Dir = Join-Path $Root ('ResourcesReport' + $Stamp)
        $null = New-Item -ItemType Directory -Path $Dir -Force
        $Json = Join-Path $Dir ('Inventory_ResourcesReport_' + $Stamp + '.json')
        Set-Content -LiteralPath $Json -Value '{"resources":[]}'
        $Zip = Join-Path $Dir ('ResourcesReport_' + $Stamp + '.zip')
        Compress-Archive -LiteralPath $Json -DestinationPath $Zip -Force
        $Zip
    }

    function script:Get-ZipEntryNames
    {
        param([string]$Path)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { @($Archive.Entries | ForEach-Object { $_.FullName }) } finally { $Archive.Dispose() }
    }

    function script:ConvertTo-Lines
    {
        process { if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }
    }
}

Describe 'Get-ConsolidatedZipProblem' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'check'
        $null = New-Item -ItemType Directory -Path $script:Root -Force
        $script:SubA = New-SubReport -Root $script:Root -Stamp 'A1'
        $script:SubB = New-SubReport -Root $script:Root -Stamp 'B1'
        $script:Both = Join-Path $script:Root 'both.zip'
        Compress-Archive -LiteralPath $script:SubA, $script:SubB -DestinationPath $script:Both -Force
        $script:OnlyA = Join-Path $script:Root 'only-a.zip'
        Compress-Archive -LiteralPath $script:SubA -DestinationPath $script:OnlyA -Force
        $script:Names = @((Split-Path $script:SubA -Leaf), (Split-Path $script:SubB -Leaf))
    }

    It 'returns nothing for a zip that holds every per-subscription zip' {
        Get-ConsolidatedZipProblem -Path $script:Both -SubZipNames $script:Names | Should -BeNullOrEmpty
    }

    It 'says the zip is not on disk when it is missing' {
        Get-ConsolidatedZipProblem -Path (Join-Path $script:Root 'gone.zip') -SubZipNames $script:Names | Should -Be 'the zip is not on disk.'
        Get-ConsolidatedZipProblem -Path '' -SubZipNames $script:Names | Should -Be 'the zip is not on disk.'
    }

    It 'says the zip cannot be read when the file is not a zip' {
        $NotZip = Join-Path $script:Root 'truncated.zip'
        Set-Content -LiteralPath $NotZip -Value 'PK not a zip'
        Get-ConsolidatedZipProblem -Path $NotZip -SubZipNames $script:Names | Should -BeLike 'the zip cannot be read: *'
    }

    It 'counts the per-subscription zips that are not in it' {
        Get-ConsolidatedZipProblem -Path $script:OnlyA -SubZipNames $script:Names | Should -Be '1 of the 2 per-subscription zip(s) are not in it.'
    }
}

Describe 'Run-AllSubscriptions.ps1: building the consolidated zip' {
    BeforeAll {
        $script:BundleBlock = [scriptblock]::Create((Find-WrapperIf -Condition 'Test-Path -Path $InventoryRoot -PathType Container' -Contains 'AllSubscriptions_ResourcesReport_').Extent.Text)

        # Runs the lifted bundling block over $Root with the variables it reads.
        function script:Invoke-BundleBlock
        {
            param([string]$Root)
            # Set-Variable: these are read only by the lifted block.
            Set-Variable -Name InventoryRoot -Value $Root
            Set-Variable -Name RunStartTime -Value ((Get-Date).AddMinutes(-5))
            $OuterZipFile = $null
            $BundleBuildError = $null
            $Printed = @(. $script:BundleBlock 6>&1 | ConvertTo-Lines)
            [pscustomobject]@{ OuterZipFile = $OuterZipFile; BundleBuildError = $BundleBuildError; Printed = $Printed; SubZips = $SubZips }
        }
    }

    It 'a consolidated zip of another run with the same second''s name is never written over: this run takes the next free name' {
        $Root = Join-Path $TestDrive 'same-second'
        $null = New-SubReport -Root $Root -Stamp 'X1'
        # What Get-Date -Format returns: the formatted text.
        Mock Get-Date { '2026-11-02_15-04-05' } -ParameterFilter { $Format -eq 'yyyy-MM-dd_HH-mm-ss' }
        $Other = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-11-02_15-04-05.zip'
        Set-Content -LiteralPath $Other -Value 'another run' -NoNewline
        $R = Invoke-BundleBlock -Root $Root
        $R.BundleBuildError | Should -BeNullOrEmpty
        $R.OuterZipFile | Should -Be (Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-11-02_15-04-05-2.zip')
        Get-Content -LiteralPath $Other -Raw | Should -Be 'another run'
        (Get-ZipEntryNames -Path $R.OuterZipFile) | Should -Be @('ResourcesReport_X1.zip')
    }

    It 'the name it took stays on disk while the zip is built: the zip is written under a name of its own in the folder, then moved over it, and that file is not left' {
        $Root = Join-Path $TestDrive 'reserved-kept'
        $null = New-SubReport -Root $Root -Stamp 'R1'
        $null = New-SubReport -Root $Root -Stamp 'R2'
        Mock Get-Date { '2026-11-02_15-04-05' } -ParameterFilter { $Format -eq 'yyyy-MM-dd_HH-mm-ss' }
        $script:ReservedName = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-11-02_15-04-05.zip'
        $script:Builds = @()
        # Notes where it writes and whether the name taken is still there, then
        # writes a zip of every report given to a new file there.
        Mock Compress-Archive -ParameterFilter { -not $Update } {
            $script:Builds += [pscustomobject]@{ Destination = $DestinationPath; ReservedThere = (Test-Path -LiteralPath $script:ReservedName -PathType Leaf) }
            $Zip = [System.IO.Compression.ZipFile]::Open($DestinationPath, 'Create')
            try { foreach ($Report in @($Path)) { $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Zip, $Report, (Split-Path $Report -Leaf)) } } finally { $Zip.Dispose() }
        }
        $R = Invoke-BundleBlock -Root $Root

        $script:Builds.Count | Should -Be 1
        $script:Builds[0].ReservedThere | Should -BeTrue
        $script:Builds[0].Destination | Should -Not -Be $script:ReservedName
        Split-Path $script:Builds[0].Destination -Parent | Should -Be $Root
        Split-Path $script:Builds[0].Destination -Leaf | Should -Not -BeLike '*.zip'
        $R.BundleBuildError | Should -BeNullOrEmpty
        $R.OuterZipFile | Should -Be $script:ReservedName
        (Get-ZipEntryNames -Path $R.OuterZipFile | Sort-Object) | Should -Be @('ResourcesReport_R1.zip', 'ResourcesReport_R2.zip')
        @(Get-ChildItem -LiteralPath $Root -File -Force | ForEach-Object { $_.Name }) | Should -Be @('AllSubscriptions_ResourcesReport_2026-11-02_15-04-05.zip')
    }

    It 'a build that fails part-way leaves no file in the folder: neither the part written nor the name it took' {
        $Root = Join-Path $TestDrive 'part-written'
        $null = New-SubReport -Root $Root -Stamp 'P1'
        Mock Compress-Archive -ParameterFilter { -not $Update } {
            Set-Content -LiteralPath $DestinationPath -Value 'PK part' -NoNewline
            throw [System.IO.IOException]::new('No space left on device')
        }
        $R = Invoke-BundleBlock -Root $Root

        $R.BundleBuildError | Should -BeLike '*: No space left on device'
        $R.OuterZipFile | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $Root -File -Force | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
    }

    It 'a written zip that cannot be read fails the check before it takes the name: no file is left under the name or the name it was written to' {
        $Root = Join-Path $TestDrive 'unreadable'
        $null = New-SubReport -Root $Root -Stamp 'U1'
        # Writes bytes that are not a zip, without an error.
        Mock Compress-Archive -ParameterFilter { -not $Update } { Set-Content -LiteralPath $DestinationPath -Value 'not a zip' -NoNewline }
        $R = Invoke-BundleBlock -Root $Root

        $R.BundleBuildError | Should -BeLike '*: the zip cannot be read: *'
        $R.OuterZipFile | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' }).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object { $_.Name -like 'AllSubscriptions_*.zip' -or $_.Name -like '.rda-*.partial' }) | Should -BeNullOrEmpty
    }

    It 'a consolidated zip that cannot be built leaves no empty file under the name it took' {
        $Root = Join-Path $TestDrive 'reserved-failed'
        $null = New-SubReport -Root $Root -Stamp 'F9'
        Mock Compress-Archive { throw [System.IO.IOException]::new('No space left on device') } -ParameterFilter { -not $Update }
        $R = Invoke-BundleBlock -Root $Root
        $R.BundleBuildError | Should -Not -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $Root -Filter 'AllSubscriptions_ResourcesReport_*.zip' -File) | Should -BeNullOrEmpty
    }

    It 'a report zip held open by another process: the error names it, no zip is reported as written' {
        $Root = Join-Path $TestDrive 'locked'
        $null = New-SubReport -Root $Root -Stamp 'L1'
        $Held = New-SubReport -Root $Root -Stamp 'L2'
        $Lock = [System.IO.File]::Open($Held, 'Open', 'ReadWrite', 'None')
        try { $R = Invoke-BundleBlock -Root $Root } finally { $Lock.Dispose() }

        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' }).Count | Should -Be 0
        @($R.Printed | Where-Object { $_ -like 'ERROR: Could not build *AllSubscriptions_ResourcesReport_*.zip: *' }).Count | Should -Be 1
        $R.BundleBuildError | Should -BeLike ('*{0}*' -f (Split-Path $Held -Leaf))
        $R.OuterZipFile | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $Root -Filter 'AllSubscriptions_ResourcesReport_*.zip').Count | Should -Be 0
    }

    It 'a write that finishes without error but leaves a report out is a failure too' {
        $Root = Join-Path $TestDrive 'short'
        $null = New-SubReport -Root $Root -Stamp 'X1'
        $null = New-SubReport -Root $Root -Stamp 'X2'
        # Writes a real zip that holds only the first report.
        Mock Compress-Archive {
            $Zip = [System.IO.Compression.ZipFile]::Open($DestinationPath, 'Create')
            try { $null = $Zip.CreateEntry((Split-Path @($Path)[0] -Leaf)) } finally { $Zip.Dispose() }
        }
        $R = Invoke-BundleBlock -Root $Root

        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' }).Count | Should -Be 0
        $R.BundleBuildError | Should -BeLike '*: 1 of the 2 per-subscription zip(s) are not in it.'
        $R.OuterZipFile | Should -BeNullOrEmpty
        # Neither the zip that failed the check nor the file it was written to is left.
        @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object { $_.Name -like 'AllSubscriptions_*.zip' -or $_.Name -like '.rda-*.partial' }) | Should -BeNullOrEmpty
    }

    It 'a zip that is built holds every report, and its path waits for the last check' {
        $Root = Join-Path $TestDrive 'good'
        $null = New-SubReport -Root $Root -Stamp 'K1'
        $null = New-SubReport -Root $Root -Stamp 'K2'
        $R = Invoke-BundleBlock -Root $Root

        $R.BundleBuildError | Should -BeNullOrEmpty
        $R.OuterZipFile | Should -BeLike (Join-Path $Root 'AllSubscriptions_ResourcesReport_*.zip')
        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' -or $_ -like 'Consolidated Report:*' }).Count | Should -Be 0
        (Get-ZipEntryNames -Path $R.OuterZipFile | Sort-Object) | Should -Be (@($R.SubZips.Name) | Sort-Object)
    }
}

Describe 'Run-AllSubscriptions.ps1: adding the run summary to the consolidated zip' {
    BeforeAll {
        $script:FoldBlock = [scriptblock]::Create((Find-WrapperIf -Condition '$null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile)' -Contains 'Bundle finalized').Extent.Text)
        $script:FinalCheckIf = Find-WrapperIf -Condition '$null -ne $OuterZipFile' -Contains 'was lost while the run summary was added'
        $script:FinalCheckBlock = [scriptblock]::Create($script:FinalCheckIf.Extent.Text)

        # A built consolidated zip in $Root, then the lifted fold block and the check after it.
        function script:Invoke-FoldBlock
        {
            param([string]$Root, [switch]$GoneBeforeFold)
            $SubZips = @((New-SubReport -Root $Root -Stamp 'F1'), (New-SubReport -Root $Root -Stamp 'F2') | ForEach-Object { Get-Item -LiteralPath $_ })
            $OuterZipFile = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-01_00-00-00.zip'
            Microsoft.PowerShell.Archive\Compress-Archive -LiteralPath $SubZips.FullName -DestinationPath $OuterZipFile -Force
            if ($GoneBeforeFold) { Remove-Item -LiteralPath $OuterZipFile -Force }
            # Set-Variable: these are read only by the lifted blocks.
            Set-Variable -Name InventoryRoot -Value $Root
            Set-Variable -Name RunStartTime -Value ((Get-Date).AddMinutes(-5))
            Set-Variable -Name MainSummaryFile -Value $null
            Set-Variable -Name FailedSubscriptions -Value @()
            $BundleBuildError = $null
            $Printed = @(. { . $script:FoldBlock; . $script:FinalCheckBlock } 6>&1 | ConvertTo-Lines)
            # Path: the zip's name as built, which a failed check sets back to $null in OuterZipFile.
            [pscustomobject]@{ Path = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-01_00-00-00.zip'; OuterZipFile = $OuterZipFile; BundleBuildError = $BundleBuildError; Printed = $Printed }
        }

        function script:Get-PathLines
        {
            param($R)
            @($R.Printed | Where-Object { $_ -eq ('Reporting Data File: {0}' -f $R.Path) -or $_ -eq ('Consolidated Report:     {0}' -f $R.Path) })
        }

        # The consolidated zips and the files they are written to, left in $Root.
        function script:Get-BundleFiles
        {
            param([string]$Root)
            @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object { $_.Name -like 'AllSubscriptions_*.zip' -or $_.Name -like '.rda-*.partial' } | ForEach-Object { $_.Name })
        }
    }

    It 'a fold that removes the zip (what a full disk does) makes the run report the zip as lost' {
        # What the real cmdlet does when -Update hits a full disk: it removes the zip and fails.
        Mock Compress-Archive -ParameterFilter { $Update } {
            Remove-Item -LiteralPath $DestinationPath -Force
            throw [System.IO.IOException]::new('No space left on device')
        }
        $R = Invoke-FoldBlock -Root (Join-Path $TestDrive 'fold-lost')

        $R.BundleBuildError | Should -Be ('{0} was lost while the run summary was added to it: the zip is not on disk.' -f $R.Path)
        $R.OuterZipFile | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'Bundle finalized*' }).Count | Should -Be 0
        @($R.Printed | Where-Object { $_ -eq ('ERROR: {0}' -f $R.BundleBuildError) }).Count | Should -Be 1
        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' -or $_ -like 'Consolidated Report:*' }).Count | Should -Be 0
    }

    It 'a zip that is gone before the run summary is added is reported as lost too' {
        $R = Invoke-FoldBlock -Root (Join-Path $TestDrive 'gone-before') -GoneBeforeFold

        $R.BundleBuildError | Should -Be ('{0} was lost while the run summary was added to it: the zip is not on disk.' -f $R.Path)
        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' -or $_ -like 'Consolidated Report:*' }).Count | Should -Be 0
        Test-Path -LiteralPath $R.Path | Should -BeFalse
    }

    It 'a fold that leaves a report out of the zip without an error: the zip is reported as lost and is not left under its name' {
        # Rewrites the zip with the staged extras only, and does not fail.
        Mock Compress-Archive -ParameterFilter { $Update } {
            Remove-Item -LiteralPath $DestinationPath -Force
            $Zip = [System.IO.Compression.ZipFile]::Open($DestinationPath, 'Create')
            try { foreach ($Item in @($Path)) { if (Test-Path -LiteralPath $Item -PathType Leaf) { $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Zip, $Item, (Split-Path $Item -Leaf)) } } } finally { $Zip.Dispose() }
        }
        $Root = Join-Path $TestDrive 'fold-short'
        $R = Invoke-FoldBlock -Root $Root

        $R.BundleBuildError | Should -Be ('{0} was lost while the run summary was added to it: 2 of the 2 per-subscription zip(s) are not in it.' -f $R.Path)
        $R.OuterZipFile | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' -or $_ -like 'Consolidated Report:*' }).Count | Should -Be 0
        script:Get-BundleFiles -Root $Root | Should -BeNullOrEmpty
    }

    It 'a fold that fails but leaves every report in the zip is only a warning' {
        Mock Compress-Archive -ParameterFilter { $Update } { throw [System.IO.IOException]::new('No space left on device') }
        $R = Invoke-FoldBlock -Root (Join-Path $TestDrive 'fold-kept')

        $R.BundleBuildError | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'WARNING: Could not fold run-summary*No space left on device*' }).Count | Should -Be 1
        @($R.Printed | Where-Object { $_ -like 'ERROR:*' }).Count | Should -Be 0
        (Get-PathLines $R).Count | Should -Be 2
    }

    It 'a fold that works keeps every report and adds the run summary, then prints the path' {
        $R = Invoke-FoldBlock -Root (Join-Path $TestDrive 'fold-good')

        $R.BundleBuildError | Should -BeNullOrEmpty
        $Names = Get-ZipEntryNames -Path $R.OuterZipFile
        $Names | Should -Contain 'RunSummary.log'
        @($Names | Where-Object { $_ -like 'ResourcesReport_F*.zip' }).Count | Should -Be 2
        (Get-PathLines $R).Count | Should -Be 2
        # After the fold's own line, not before it.
        $Finalized = [array]::IndexOf($R.Printed, @($R.Printed | Where-Object { $_ -like 'Bundle finalized*' })[0])
        $Finalized | Should -BeGreaterOrEqual 0
        [array]::IndexOf($R.Printed, (Get-PathLines $R)[0]) | Should -BeGreaterThan $Finalized
    }

    It 'the wrapper prints the path of the consolidated zip only after that last check' {
        $PathWrites = @($script:WrapperAst.FindAll({
                    $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                    $args[0].GetCommandName() -eq 'Write-Host' -and
                    ($args[0].Extent.Text.Contains('Reporting Data File:') -or $args[0].Extent.Text.Contains('Consolidated Report:'))
                }, $true))
        $PathWrites.Count | Should -Be 2
        foreach ($W in $PathWrites)
        {
            $W.Extent.StartOffset | Should -BeGreaterThan $script:FinalCheckIf.Extent.StartOffset
            $W.Extent.EndOffset | Should -BeLessThan $script:FinalCheckIf.Extent.EndOffset
        }
    }
}

Describe 'Run-AllSubscriptions.ps1: the end of a run without a consolidated zip' {
    BeforeAll {
        $script:BannerBlock = [scriptblock]::Create((Find-WrapperIf -Condition '$null -ne $BundleBuildError' -Contains 'FAILED (consolidated zip)').Extent.Text)
        $ExitIf = Find-WrapperIf -Condition '$null -ne $BundleBuildError' -Contains 'exit 2'
        # From the exit-2 check to the end of the wrapper: the exit-code statements as they run.
        $script:TailText = $script:WrapperAst.Extent.Text.Substring($ExitIf.Extent.StartOffset - $script:WrapperAst.Extent.StartOffset)
        $script:Pwsh = (Get-Process -Id $PID).Path

        # Any other variable the tail reads but does not assign is a list the wrapper
        # fills during the run; in these runs it is empty.
        $TailAst = [System.Management.Automation.Language.Parser]::ParseInput($script:TailText, [ref]$null, [ref]$null)
        $Assigned = @($TailAst.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath })
        $Given = @('null', 'true', 'false', 'BundleBuildError', 'AuthSkippedPhases', 'Global:CollectorFailures')
        $script:EmptyLists = @($TailAst.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
                ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique | Where-Object { $Assigned -notcontains $_ -and $Given -notcontains $_ })

        # Runs the wrapper's tail in a child pwsh, since it ends with 'exit'. Returns the exit code.
        function script:Invoke-Tail
        {
            param([string]$BundleBuildError, [string[]]$AuthSkippedPhases = @(), [int]$CollectorFailureCount = 0)
            $Script = Join-Path $TestDrive ('tail-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
            $Preamble = @(
                ('. ''{0}''' -f $script:FunctionsPath.Replace("'", "''"))
                $(if ($BundleBuildError) { '$BundleBuildError = ''{0}''' -f $BundleBuildError.Replace("'", "''") } else { '$BundleBuildError = $null' })
                ('$AuthSkippedPhases = @({0})' -f ((@($AuthSkippedPhases) | ForEach-Object { "'$_'" }) -join ','))
                $(if ($CollectorFailureCount -gt 0) { '$Global:CollectorFailures = @(1..{0} | ForEach-Object {{ [pscustomobject]@{{ Id = ''sub'' }} }})' -f $CollectorFailureCount } else { '$Global:CollectorFailures = @()' })
            ) + @($script:EmptyLists | ForEach-Object { '${0} = @()' -f $_ })
            Set-Content -LiteralPath $Script -Value (($Preamble -join "`n") + "`n" + $script:TailText)
            & $script:Pwsh -NoProfile -NonInteractive -File $Script *> $null
            $LASTEXITCODE
        }
    }

    It 'the banner names the zip, the cause and where the reports are' {
        $InventoryRoot = Join-Path $TestDrive 'inv'
        $BundleBuildError = 'Could not build /x/AllSubscriptions_ResourcesReport_1.zip: No space left on device'
        $Printed = @(. $script:BannerBlock 6>&1 | ConvertTo-Lines)

        $Printed | Should -Contain '================ FAILED (consolidated zip) ================'
        $Printed | Should -Contain $BundleBuildError
        $Printed | Should -Contain ('The per-subscription report zips of this run are still on disk under {0}.' -f $InventoryRoot)
    }

    It 'no banner when the zip was built' {
        Set-Variable -Name InventoryRoot -Value (Join-Path $TestDrive 'inv')
        Set-Variable -Name BundleBuildError -Value $null
        @(. $script:BannerBlock 6>&1 | ConvertTo-Lines).Count | Should -Be 0
    }

    It 'exit code 2 when the zip is missing, also over 3-5' {
        Invoke-Tail -BundleBuildError 'Could not build x: y' | Should -Be 2
        Invoke-Tail -BundleBuildError 'Could not build x: y' -AuthSkippedPhases 'Metrics' -CollectorFailureCount 1 | Should -Be 2
    }

    It 'the other exit codes are unchanged when the zip was built' {
        Invoke-Tail -BundleBuildError $null | Should -Be 0
        Invoke-Tail -BundleBuildError $null -AuthSkippedPhases 'Metrics' | Should -Be 3
        Invoke-Tail -BundleBuildError $null -CollectorFailureCount 1 | Should -Be 4
        Invoke-Tail -BundleBuildError $null -AuthSkippedPhases 'Metrics' -CollectorFailureCount 1 | Should -Be 5
    }
}

Describe 'New-RunOutputFile: a new file, never one that is there' {
    It 'creates the name given when it is free' {
        $Path = New-RunOutputFile -Directory $TestDrive -Stem 'MainSummary_2026-11-02_15-04-05' -Extension '.html'
        $Path | Should -Be (Join-Path $TestDrive 'MainSummary_2026-11-02_15-04-05.html')
        (Get-Item -LiteralPath $Path).Length | Should -Be 0
    }

    It 'takes -2, then -3, when the names before are there, and leaves those files as they were' {
        $Dir = Join-Path $TestDrive 'taken'
        $null = New-Item -ItemType Directory -Path $Dir
        Set-Content -LiteralPath (Join-Path $Dir 'RunAllSubscriptions_transcript_x.txt') -Value 'first' -NoNewline
        (New-RunOutputFile -Directory $Dir -Stem 'RunAllSubscriptions_transcript_x' -Extension '.txt') | Should -Be (Join-Path $Dir 'RunAllSubscriptions_transcript_x-2.txt')
        (New-RunOutputFile -Directory $Dir -Stem 'RunAllSubscriptions_transcript_x' -Extension '.txt') | Should -Be (Join-Path $Dir 'RunAllSubscriptions_transcript_x-3.txt')
        Get-Content -LiteralPath (Join-Path $Dir 'RunAllSubscriptions_transcript_x.txt') -Raw | Should -Be 'first'
    }

    It 'says so when every name up to -100 is taken, and creates nothing' {
        $Dir = Join-Path $TestDrive 'full'
        $null = New-Item -ItemType Directory -Path $Dir
        $null = New-Item -ItemType File -Path (Join-Path $Dir 'z.zip')
        foreach ($N in 2..100) { $null = New-Item -ItemType File -Path (Join-Path $Dir ('z-{0}.zip' -f $N)) }
        { New-RunOutputFile -Directory $Dir -Stem 'z' -Extension '.zip' } | Should -Throw 'every name from z.zip to z-100.zip is taken'
        @(Get-ChildItem -LiteralPath $Dir -File).Count | Should -Be 100
    }
}

Describe 'Run-AllSubscriptions.ps1: the transcript and the main summary of the same second' {
    It 'the wrapper transcript takes its name from New-RunOutputFile, so it never writes over another run''s transcript' {
        $Try = @($script:WrapperAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text.Contains('Start-Transcript -Path $WrapperTranscriptFile') })
        $Try.Count | Should -Be 1
        $Root = Join-Path $TestDrive 'transcript'
        $null = New-Item -ItemType Directory -Path $Root
        Mock Get-Date { '2026-11-02_15-04-05' } -ParameterFilter { $Format -eq 'yyyy-MM-dd_HH-mm-ss' }
        Set-Content -LiteralPath (Join-Path $Root 'RunAllSubscriptions_transcript_2026-11-02_15-04-05.txt') -Value 'another run' -NoNewline
        Mock Start-Transcript { }
        Set-Variable -Name InventoryRoot -Value $Root
        $WrapperTranscriptFile = $null
        $null = @(. ([scriptblock]::Create($Try[0].Extent.Text)) 6>&1)
        $WrapperTranscriptFile | Should -Be (Join-Path $Root 'RunAllSubscriptions_transcript_2026-11-02_15-04-05-2.txt')
        Get-Content -LiteralPath (Join-Path $Root 'RunAllSubscriptions_transcript_2026-11-02_15-04-05.txt') -Raw | Should -Be 'another run'
    }

    It 'a main summary that cannot be built leaves no empty file under the name it took and is not added to the zip' {
        $SummaryIf = Find-WrapperIf -Condition '$null -ne $OuterZipFile' -Contains 'New-RdaAllSubHtmlSummary'
        # The block loads the summary functions from the wrapper's folder; here a
        # stand-in folder whose builder fails.
        $Fake = Join-Path $TestDrive 'fake-root'
        $null = New-Item -ItemType Directory -Path (Join-Path $Fake 'Functions') -Force
        Set-Content -LiteralPath (Join-Path $Fake 'Functions/AllSubHtmlSummary.Functions.ps1') -Value 'function New-RdaAllSubHtmlSummary { throw "disk full" }'
        $Text = $SummaryIf.Extent.Text.Replace('$PSScriptRoot', ('''{0}''' -f $Fake.Replace("'", "''")))
        $Root = Join-Path $TestDrive 'summary-failed'
        $null = New-Item -ItemType Directory -Path $Root
        Set-Variable -Name InventoryRoot -Value $Root
        Set-Variable -Name OuterZipFile -Value (Join-Path $Root 'AllSubscriptions_ResourcesReport_x.zip')
        Set-Variable -Name RunStartTime -Value (Get-Date)
        $MainSummaryFile = $null
        $Printed = @(. ([scriptblock]::Create($Text)) 6>&1 | ConvertTo-Lines)
        @($Printed | Where-Object { $_ -like 'WARNING: Could not build the main summary: disk full' }).Count | Should -Be 1
        $MainSummaryFile | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $Root -Filter 'MainSummary_*.html' -File) | Should -BeNullOrEmpty
    }
}