#Requires -Version 7.0
<#
    Offline, self-contained Pester coverage for FindResource.ps1 and
    Functions/FindResource.Functions.ps1.

    Makes NO Azure calls and reads no pre-generated zip. Every fixture is built
    synthetically in a temp directory, because the load-bearing logic here is a
    CLASSIFIER, not a renderer: Get-RdaTypeCoverage decides whether the tool is
    entitled to call a zero a confirmed absence, and that decision has to be
    provable for inputs a real estate will not conveniently supply (a bundle
    predating a collector, a de-obfuscated report left on disk, a subscription
    reachable by two paths).

    A wrong "no" is this tool's worst possible output, so the absence-gate
    assertions below are the ones that matter most. The rest guard the artifact
    the operator takes away.

    All fixture data is invented. No real subscription, tenant, resource or
    customer identifier appears anywhere in this file.
#>

BeforeAll {
    $Script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $Script:EntryPoint = Join-Path $Script:RepoRoot 'FindResource.ps1'
    . (Join-Path $Script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $Script:RepoRoot 'Functions/FindResource.Functions.ps1')

    $Script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("RdaFindResourceTests_{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $Script:TestRoot -Force | Out-Null

    # Report stamps must satisfy the 15+ digit contract Get-RdaReportId keys on.
    $Script:StampA = '202601010000000000001'
    $Script:StampB = '202601010000000000002'
    $Script:StampC = '202601010000000000003'

    function Script:New-InventoryJson
    {
        <#
            Builds one synthetic Inventory_*.json. -OmitVMWare leaves the VMWare
            KEY OUT ENTIRELY, which is how a bundle predating the collector looks
            and is a different state from the key being present with zero rows.
        #>
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [int]$AvsCount = 0,
            [switch]$OmitVMWare,
            [int]$ClusterSize = 6,
            [string]$Sku = 'AV36',
            [string]$Marker = 'obfuscated'
        )

        $Body = [ordered]@{ Version = '9.9.9' }
        $Body['VirtualMachines'] = @(
            [ordered]@{ Name = ('{0}_vm1' -f $Marker); Location = 'westeurope'; Size = 'standard_d2s_v3' }
        )

        if (-not $OmitVMWare)
        {
            $Rows = @()
            for ($I = 0; $I -lt $AvsCount; $I++)
            {
                $Rows += [ordered]@{
                    ID                   = ('{0}_avsid{1}' -f $Marker, $I)
                    Name                 = ('{0}_avs{1}' -f $Marker, $I)
                    Subscription         = ('{0}_sub' -f $Marker)
                    ResourceGroup        = ('{0}_rg' -f $Marker)
                    Location             = 'switzerlandnorth'
                    SKU                  = $Sku
                    AvailabilityStrategy = 'singlezone'
                    Encryption           = 'enabled'
                    ClusterSize          = $ClusterSize
                }
            }
            # An empty array is the "collector ran, found nothing" shape.
            $Body['VMWare'] = $Rows
        }

        $Body | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
    }

    function Script:New-PerSubZip
    {
        param(
            [Parameter(Mandatory = $true)][string]$ZipPath,
            [Parameter(Mandatory = $true)][string]$Stamp,
            [int]$AvsCount = 0,
            [switch]$OmitVMWare,
            [string]$Marker = 'obfuscated'
        )

        $Staging = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Staging -Force | Out-Null
        try
        {
            $Inv = Join-Path $Staging ('Inventory_ResourcesReport_{0}.json' -f $Stamp)
            $SplatArgs = @{ Path = $Inv; AvsCount = $AvsCount; Marker = $Marker }
            if ($OmitVMWare) { $SplatArgs.OmitVMWare = $true }
            New-InventoryJson @SplatArgs

            # A realistic decoy member, so a test proves the reader targets the
            # inventory entry rather than simply reading whatever it finds first.
            Set-Content -LiteralPath (Join-Path $Staging ('Consumption_ResourcesReport_{0}.csv' -f $Stamp)) -Value 'a,b', '1,2' -Encoding UTF8

            if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
            Compress-Archive -Path (Join-Path $Staging '*') -DestinationPath $ZipPath -Force
        }
        finally { Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

AfterAll {
    if ($Script:TestRoot -and (Test-Path -LiteralPath $Script:TestRoot))
    {
        Remove-Item -LiteralPath $Script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RdaTypeCoverage - the absence gate classifier' {

    It 'classifies Full when every inventory read carried the key' {
        $R = New-RdaFindResult -UnitsRead 10 -TypePresence @{ 'VMWare' = 10 } -ResourceType @('VMWare')
        (Get-RdaTypeCoverage -Result $R)['VMWare'] | Should -Be 'Full'
    }

    It 'classifies Partial when only some inventories carried the key' {
        # The regression that matters: a counter-based gate reported this as a
        # confirmed zero because it only tested "is the count non-zero".
        $R = New-RdaFindResult -UnitsRead 244 -TypePresence @{ 'VMWare' = 4 } -ResourceType @('VMWare')
        (Get-RdaTypeCoverage -Result $R)['VMWare'] | Should -Be 'Partial'
    }

    It 'classifies None when no inventory carried the key' {
        $R = New-RdaFindResult -UnitsRead 10 -TypePresence @{ 'VMWare' = 0 } -ResourceType @('VMWare')
        (Get-RdaTypeCoverage -Result $R)['VMWare'] | Should -Be 'None'
    }

    It 'fails CLOSED to None when nothing was read' {
        $R = New-RdaFindResult -UnitsRead 0 -TypePresence @{ 'VMWare' = 0 } -ResourceType @('VMWare')
        (Get-RdaTypeCoverage -Result $R)['VMWare'] | Should -Be 'None'
    }

    It 'fails CLOSED to None when TypePresence is not a usable dictionary' {
        # A JSON round-trip turns the hashtable into a PSCustomObject. That must
        # degrade toward "cannot confirm", never toward a confident zero.
        $R = New-RdaFindResult -UnitsRead 10 -TypePresence ([pscustomobject]@{ VMWare = 10 }) -ResourceType @('VMWare')
        (Get-RdaTypeCoverage -Result $R)['VMWare'] | Should -Be 'None'
    }

    It 'fails CLOSED to None if a count somehow exceeds the number read' {
        $R = New-RdaFindResult -UnitsRead 5 -TypePresence @{ 'VMWare' = 7 } -ResourceType @('VMWare')
        (Get-RdaTypeCoverage -Result $R)['VMWare'] | Should -Be 'None'
    }
}

Describe 'Write-RdaFindSummary - only a complete scan earns "confirmed zero"' {

    It 'says confirmed zero when coverage is Full and nothing was lost' {
        $R = New-RdaFindResult -UnitsRead 3 -ReadCount 3 -SourceCount 3 `
            -TypePresence @{ 'VMWare' = 3 } -ResourceType @('VMWare')
        $Out = Write-RdaFindSummary -Result $R 6>&1 | Out-String
        $Out | Should -Match 'confirmed zero'
    }

    It 'refuses to say confirmed zero when the key was in NO inventory' {
        $R = New-RdaFindResult -UnitsRead 3 -ReadCount 3 -SourceCount 3 `
            -TypePresence @{ 'VMWare' = 0 } -ResourceType @('VMWare')
        $Out = Write-RdaFindSummary -Result $R 6>&1 | Out-String
        $Out | Should -Match 'CANNOT CONFIRM ABSENCE'
        $Out | Should -Not -Match 'confirmed zero'
    }

    It 'refuses to say confirmed zero on PARTIAL coverage, and names the shortfall' {
        $R = New-RdaFindResult -UnitsRead 244 -ReadCount 244 -SourceCount 244 `
            -TypePresence @{ 'VMWare' = 4 } -ResourceType @('VMWare')
        $Out = Write-RdaFindSummary -Result $R 6>&1 | Out-String
        $Out | Should -Match 'PARTIAL COVERAGE'
        $Out | Should -Match 'only 4 of 244'
        # Asserted against the AFFIRMATIVE sentence, not the bare phrase: the
        # partial branches legitimately contain "NOT a confirmed zero", so a
        # substring test on 'confirmed zero' alone would fail on correct output.
        $Out | Should -Not -Match 'This is a confirmed zero'
    }

    It 'refuses to say confirmed zero when a path was refused by the PII guard' {
        $R = New-RdaFindResult -UnitsRead 3 -ReadCount 3 -SourceCount 3 `
            -TypePresence @{ 'VMWare' = 3 } -ResourceType @('VMWare') `
            -Rejected @('somewhere_revealed/report.zip (refused)')
        $Out = Write-RdaFindSummary -Result $R 6>&1 | Out-String
        $Out | Should -Match 'PARTIAL SCAN'
        $Out | Should -Not -Match 'This is a confirmed zero'
    }

    It 'refuses to say confirmed zero when a subtree could not be enumerated' {
        $R = New-RdaFindResult -UnitsRead 3 -ReadCount 3 -SourceCount 3 `
            -TypePresence @{ 'VMWare' = 3 } -ResourceType @('VMWare') `
            -Unreadable @('/some/dir: access denied')
        $Out = Write-RdaFindSummary -Result $R 6>&1 | Out-String
        $Out | Should -Not -Match 'This is a confirmed zero'
    }

    It 'says nothing was scanned, not "check the type", when no source was found' {
        $R = New-RdaFindResult -SourceCount 0 -UnitsRead 0 `
            -TypePresence @{ 'VMWare' = 0 } -ResourceType @('VMWare')
        $Out = Write-RdaFindSummary -Result $R 6>&1 | Out-String
        $Out | Should -Match 'NOTHING WAS SCANNED'
    }

    It 'reports a duplicated read even when the duplicate contributed no rows' {
        # Detection and the named list use different keys; gating on the named
        # list alone made this case print nothing at all.
        $R = New-RdaFindResult -UnitsRead 3 -UnitReadAttempts 5 -ReadCount 3 -SourceCount 3 `
            -TypePresence @{ 'VMWare' = 3 } -ResourceType @('VMWare') -DuplicateUnits @()
        $Out = Write-RdaFindSummary -Result $R 6>&1 | Out-String
        $Out | Should -Match 'read twice'
        $Out | Should -Match 'INFLATED'
    }
}

Describe 'Get-RdaInventorySource - nothing is dropped silently' {

    BeforeAll {
        $Script:DiscoRoot = Join-Path $Script:TestRoot 'disco'
        New-Item -ItemType Directory -Path $Script:DiscoRoot -Force | Out-Null
        New-PerSubZip -ZipPath (Join-Path $Script:DiscoRoot ('ResourcesReport_{0}.zip' -f $Script:StampA)) -Stamp $Script:StampA -AvsCount 1
    }

    It 'finds a per-subscription zip' {
        $D = Get-RdaInventorySource -Path $Script:DiscoRoot
        @($D.Sources).Count | Should -Be 1
        @($D.Sources)[0].Kind | Should -Be 'PerSubZip'
    }

    It 'records a missing path instead of ignoring it' {
        $D = Get-RdaInventorySource -Path (Join-Path $Script:TestRoot 'does-not-exist')
        @($D.Missing).Count | Should -Be 1
    }

    It 'REFUSES a de-obfuscated report and RECORDS the refusal' {
        # The PII guard must make the scan visibly incomplete, not quietly smaller.
        $RevRoot = Join-Path $Script:TestRoot 'revealed-file'
        New-Item -ItemType Directory -Path $RevRoot -Force | Out-Null
        New-PerSubZip -ZipPath (Join-Path $RevRoot ('ResourcesReport_{0}_revealed.zip' -f $Script:StampB)) -Stamp $Script:StampB -AvsCount 1 -Marker 'REALNAME'

        $D = Get-RdaInventorySource -Path $RevRoot
        @($D.Sources).Count | Should -Be 0
        @($D.Rejected).Count | Should -Be 1
        @($D.Rejected)[0] | Should -Match 'de-obfuscated'
    }

    It 'REFUSES a report inside a RevealedStaging_* folder, which keeps its original name' {
        # Regression for the real hole: Reveal.ps1 all-mode stages fully revealed
        # zips under their ORIGINAL names in RevealedStaging_<ts>, so a pattern
        # requiring the literal '_revealed' misses every one of them.
        $StageRoot = Join-Path $Script:TestRoot 'staging-root'
        $Stage = Join-Path $StageRoot 'RevealedStaging_2026-01-01_00-00-00'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        New-PerSubZip -ZipPath (Join-Path $Stage ('ResourcesReport_{0}.zip' -f $Script:StampC)) -Stamp $Script:StampC -AvsCount 1 -Marker 'REALNAME'

        $D = Get-RdaInventorySource -Path $StageRoot
        @($D.Sources).Count | Should -Be 0
        @($D.Rejected).Count | Should -Be 1
    }

    It 'refuses a file that is not a report artifact rather than failing later as "not a zip"' {
        $Junk = Join-Path $Script:TestRoot 'notes.txt'
        Set-Content -LiteralPath $Junk -Value 'not a report' -Encoding UTF8
        $D = Get-RdaInventorySource -Path $Junk
        @($D.Sources).Count | Should -Be 0
        @($D.Rejected)[0] | Should -Match 'not a report artifact'
    }

    It 'de-duplicates a loose inventory and its sibling zip to ONE source, preferring the loose json' {
        $Both = Join-Path $Script:TestRoot 'both-forms'
        New-Item -ItemType Directory -Path $Both -Force | Out-Null
        New-InventoryJson -Path (Join-Path $Both ('Inventory_ResourcesReport_{0}.json' -f $Script:StampA)) -AvsCount 1
        New-PerSubZip -ZipPath (Join-Path $Both ('ResourcesReport_{0}.zip' -f $Script:StampA)) -Stamp $Script:StampA -AvsCount 1

        $D = Get-RdaInventorySource -Path $Both
        @($D.Sources).Count | Should -Be 1
        @($D.Sources)[0].Kind | Should -Be 'LooseJson'
    }
}

Describe 'Find-RdaResource - reading and counting' {

    BeforeAll {
        # Three subscriptions: two carry AVS, one has the key present with zero
        # rows. Coverage must therefore be Full.
        $Script:FullRoot = Join-Path $Script:TestRoot 'full'
        New-Item -ItemType Directory -Path $Script:FullRoot -Force | Out-Null
        New-PerSubZip -ZipPath (Join-Path $Script:FullRoot 'ResourcesReport_202601010000000000011.zip') -Stamp '202601010000000000011' -AvsCount 2
        New-PerSubZip -ZipPath (Join-Path $Script:FullRoot 'ResourcesReport_202601010000000000012.zip') -Stamp '202601010000000000012' -AvsCount 1
        New-PerSubZip -ZipPath (Join-Path $Script:FullRoot 'ResourcesReport_202601010000000000013.zip') -Stamp '202601010000000000013' -AvsCount 0
    }

    It 'reads only the inventory entry and returns every matching row with provenance' {
        $R = Find-RdaResource -Path $Script:FullRoot -ResourceType 'VMWare' -ThrottleLimit 2
        $R.UnitsRead | Should -Be 3
        @($R.Failures).Count | Should -Be 0
        @($R.Rows).Count | Should -Be 3
        @($R.Rows)[0].PSObject.Properties.Name | Should -Contain 'RdaReportId'
        @($R.Rows)[0].PSObject.Properties.Name | Should -Contain 'RdaSourceFile'
        @($R.Rows)[0].PSObject.Properties.Name | Should -Contain 'RdaResourceType'
    }

    It 'reports Full coverage when the key is present in every inventory, including the zero-row one' {
        $R = Find-RdaResource -Path $Script:FullRoot -ResourceType 'VMWare' -ThrottleLimit 2
        $R.TypePresence['VMWare'] | Should -Be 3
        (Get-RdaTypeCoverage -Result $R)['VMWare'] | Should -Be 'Full'
    }

    It 'sums a numeric field across matches, giving the "how big is it" figure' {
        # 3 private clouds at ClusterSize 6 each.
        $R = Find-RdaResource -Path $Script:FullRoot -ResourceType 'VMWare' -SumBy 'ClusterSize' -ThrottleLimit 2
        (@($R.Rows) | Measure-Object -Property ClusterSize -Sum).Sum | Should -Be 18
    }

    It 'distinguishes key-absent from key-present-zero-rows' {
        $Mixed = Join-Path $Script:TestRoot 'mixed-vintage'
        New-Item -ItemType Directory -Path $Mixed -Force | Out-Null
        New-PerSubZip -ZipPath (Join-Path $Mixed 'ResourcesReport_202601010000000000021.zip') -Stamp '202601010000000000021' -AvsCount 0
        New-PerSubZip -ZipPath (Join-Path $Mixed 'ResourcesReport_202601010000000000022.zip') -Stamp '202601010000000000022' -OmitVMWare

        $R = Find-RdaResource -Path $Mixed -ResourceType 'VMWare' -ThrottleLimit 2
        $R.UnitsRead | Should -Be 2
        $R.TypePresence['VMWare'] | Should -Be 1
        (Get-RdaTypeCoverage -Result $R)['VMWare'] | Should -Be 'Partial'
    }

    It 'de-duplicates a repeated -ResourceType instead of double-counting coverage' {
        # A counter-based implementation inflated TypePresence past UnitsRead here
        # and reported Partial coverage as Full.
        $R = Find-RdaResource -Path $Script:FullRoot -ResourceType 'VMWare', 'VMWare', 'vmware' -ThrottleLimit 2
        $R.TypePresence['VMWare'] | Should -Be 3
        $R.TypePresence['VMWare'] | Should -Not -BeGreaterThan $R.UnitsRead
    }

    It 'records a read failure for a malformed inventory instead of counting it as a clean read' {
        $Bad = Join-Path $Script:TestRoot 'bad-json'
        New-Item -ItemType Directory -Path $Bad -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Bad 'Inventory_ResourcesReport_202601010000000000031.json') -Value '[]' -Encoding UTF8

        $R = Find-RdaResource -Path $Bad -ResourceType 'VMWare' -ThrottleLimit 1
        @($R.Failures).Count | Should -BeGreaterThan 0
        $R.UnitsRead | Should -Be 0
    }

    It 'throws rather than scanning if the de-obfuscated-report guard pattern is unset' {
        $Saved = $Script:RdaRevealedExclusion
        try
        {
            Set-Variable -Name RdaRevealedExclusion -Scope Script -Value ''
            { Find-RdaResource -Path $Script:FullRoot -ResourceType 'VMWare' } | Should -Throw
        }
        finally { Set-Variable -Name RdaRevealedExclusion -Scope Script -Value $Saved }
    }
}

Describe 'FindResource.ps1 entry point' {

    BeforeAll {
        $Script:EntryRoot = Join-Path $Script:TestRoot 'entry'
        New-Item -ItemType Directory -Path $Script:EntryRoot -Force | Out-Null
        New-PerSubZip -ZipPath (Join-Path $Script:EntryRoot 'ResourcesReport_202601010000000000041.zip') -Stamp '202601010000000000041' -AvsCount 1
    }

    It 'rejects a mistyped -ResourceType at parameter-binding time and suggests the real name' {
        $Err = pwsh -NoProfile -File $Script:EntryPoint -Path $Script:EntryRoot -ResourceType 'VMWre' 2>&1 | Out-String
        $Err | Should -Match 'Unknown resource type'
        $Err | Should -Match 'VMWare'
    }

    It 'accepts a real collector name through the entry point validator' {
        # Binds valid names THROUGH FindResource.ps1's ValidateScript, the way
        # the sibling 'rejects a mistyped' test does. Re-deriving the Services
        # list here and asserting membership would still pass if the validator
        # were broken or replaced by a hardcoded list that drifted; only driving
        # the real binding guards against that drift.
        foreach ($Name in @('VMWare', 'VirtualMachines', 'StorageAcc'))
        {
            $Out = pwsh -NoProfile -File $Script:EntryPoint -Path $Script:EntryRoot -ResourceType $Name 2>&1 | Out-String
            $Out | Should -Not -Match 'Unknown resource type'
            $Out | Should -Not -Match 'ParameterArgumentValidationError'
        }
    }

    It 'exits 1 when nothing was scanned' {
        $Empty = Join-Path $Script:TestRoot 'entry-empty'
        New-Item -ItemType Directory -Path $Empty -Force | Out-Null
        pwsh -NoProfile -File $Script:EntryPoint -Path $Empty -ResourceType 'VMWare' > $null 2>&1
        $LASTEXITCODE | Should -Be 1
    }

    It 'exits 0 on a complete scan' {
        pwsh -NoProfile -File $Script:EntryPoint -Path $Script:EntryRoot -ResourceType 'VMWare' > $null 2>&1
        $LASTEXITCODE | Should -Be 0
    }

    It 'exits 3 when the scan did not cover everything requested' {
        # Scope loss has to reach a caller that reads only $LASTEXITCODE, because
        # the summary already refuses to call such a result a confirmed zero.
        # Driven by a refused de-obfuscated report rather than a second -Path,
        # so the whole case fits one path argument (pwsh -File passes arguments
        # as literal strings, so an array does not bind through it).
        $Partial = Join-Path $Script:TestRoot 'entry-partial'
        New-Item -ItemType Directory -Path $Partial -Force | Out-Null
        New-PerSubZip -ZipPath (Join-Path $Partial 'ResourcesReport_202601010000000000071.zip') -Stamp '202601010000000000071' -AvsCount 1
        New-PerSubZip -ZipPath (Join-Path $Partial 'ResourcesReport_202601010000000000072_revealed.zip') -Stamp '202601010000000000072' -AvsCount 1 -Marker 'REALNAME'

        pwsh -NoProfile -File $Script:EntryPoint -Path $Partial -ResourceType 'VMWare' > $null 2>&1
        $LASTEXITCODE | Should -Be 3
    }

    It 'exits 2 when an inventory could not be read' {
        # A malformed inventory is a read failure, not a clean read - and like
        # exit 3, that has to reach a caller reading only $LASTEXITCODE, since the
        # summary already refuses to call an incomplete read a confirmed zero.
        $BadEntry = Join-Path $Script:TestRoot 'entry-badjson'
        New-Item -ItemType Directory -Path $BadEntry -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $BadEntry 'Inventory_ResourcesReport_202601010000000000081.json') -Value '[]' -Encoding UTF8

        pwsh -NoProfile -File $Script:EntryPoint -Path $BadEntry -ResourceType 'VMWare' > $null 2>&1
        $LASTEXITCODE | Should -Be 2
    }

    It 'exits 4 when a matched result could not be written' {
        # A complete scan that matched rows but whose -CsvPath cannot be written
        # is an output-path problem, distinct from "nothing was scanned" (1) and
        # from scope loss (3). The path is a file under a directory that does not
        # exist, so the write fails while the scan itself is clean and complete.
        $BadCsv = Join-Path (Join-Path $Script:TestRoot 'entry-nowhere') 'out.csv'
        pwsh -NoProfile -File $Script:EntryPoint -Path $Script:EntryRoot -ResourceType 'VMWare' -CsvPath $BadCsv > $null 2>&1
        $LASTEXITCODE | Should -Be 4
    }

    It 'writes a CSV whose header is the UNION of fields across rows of differing schemas' {
        # Export-Csv headers off the first object only, so unprojected parallel rows drop columns nondeterministically.
        # Invoked via -Command (not -File) because this case binds an ARRAY to -ResourceType.
        $MixRoot = Join-Path $Script:TestRoot 'schema-mix'
        New-Item -ItemType Directory -Path $MixRoot -Force | Out-Null
        New-PerSubZip -ZipPath (Join-Path $MixRoot 'ResourcesReport_202601010000000000051.zip') -Stamp '202601010000000000051' -AvsCount 1

        $Csv = Join-Path $Script:TestRoot 'out.csv'
        $Cmd = '& "{0}" -Path "{1}" -ResourceType VMWare,VirtualMachines -CsvPath "{2}"' -f $Script:EntryPoint, $MixRoot, $Csv
        pwsh -NoProfile -Command $Cmd > $null 2>&1

        Test-Path -LiteralPath $Csv | Should -BeTrue
        $Header = (Get-Content -LiteralPath $Csv -TotalCount 1)
        # A VMWare-only field and a VirtualMachines-only field must BOTH survive.
        $Header | Should -Match 'ClusterSize'
        $Header | Should -Match 'Size'
    }

    It 'writes JSON as an array even for a single match, so the shape is stable' {
        $Json = Join-Path $Script:TestRoot 'out.json'
        pwsh -NoProfile -File $Script:EntryPoint -Path $Script:EntryRoot -ResourceType 'VMWare' -JsonPath $Json > $null 2>&1
        Test-Path -LiteralPath $Json | Should -BeTrue
        (Get-Content -LiteralPath $Json -Raw).TrimStart()[0] | Should -Be '['
    }

    It 'does NOT write an output file when nothing matched, and says so' {
        $NoMatch = Join-Path $Script:TestRoot 'nomatch'
        New-Item -ItemType Directory -Path $NoMatch -Force | Out-Null
        New-PerSubZip -ZipPath (Join-Path $NoMatch 'ResourcesReport_202601010000000000061.zip') -Stamp '202601010000000000061' -AvsCount 0

        $Csv = Join-Path $Script:TestRoot 'empty.csv'
        $Out = pwsh -NoProfile -File $Script:EntryPoint -Path $NoMatch -ResourceType 'VMWare' -CsvPath $Csv 2>&1 | Out-String
        Test-Path -LiteralPath $Csv | Should -BeFalse
        $Out | Should -Match 'was NOT written'
    }
}

Describe 'Get-RdaReportId' {

    It 'keys on the report stamp so two views of one report collapse to one unit' {
        $A = Get-RdaReportId -Name ('Inventory_ResourcesReport_{0}.json' -f $Script:StampA)
        $B = Get-RdaReportId -Name ('ResourcesReport_{0}.zip' -f $Script:StampA)
        $A | Should -Be $Script:StampA
        $A | Should -Be $B
    }

    It 'falls back to the base name rather than throwing on an unstamped name' {
        Get-RdaReportId -Name 'ResourcesReport.zip' | Should -Be 'ResourcesReport'
    }
}
