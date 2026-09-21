#Requires -Version 7.0
<#
    Reproduction + regression coverage for fable review findings W1, W2, W4 in
    Functions/FindResource.Functions.ps1.

    W1  The README "File Delivery" step tells operators to rename the per-sub /
        bundle ZIP to include a company prefix, e.g.
        CompanyName_ResourcesReport_2024-01-15.zip. Discovery filtered on the
        anchored pattern 'ResourcesReport*.zip', so that file was invisible on a
        recursive scan and Rejected as "not a report artifact" when passed
        explicitly. A folder of renamed deliverables scanned as empty.

    W2  When sources are found but every read fails (UnitsRead == 0), the summary
        blamed "the bundles predate the collector, or the run was scoped with
        -Service" - both wrong. The real story is the read failures.

    W4  A permission-denied scan root was reported as Missing ("path not found")
        rather than Unreadable, sending the operator to check spelling instead of
        ACLs.

    Later findings covered here:

    D1  (875) Discovery de-duplicated on the report stamp but fell back to the
        bare BASE NAME for stamp-less files, so two distinct stamp-less
        inventories sharing a base name in different folders collapsed into one
        Group-Object group and one was silently dropped from Sources - a false
        confirmed zero one layer before the reader. The fallback now keys on the
        FULL PATH so distinct files stay distinct.

    E1  (876/805) When candidates were found but every one was excluded
        (refused/unreadable/skipped/missing), the empty-source message still said
        "No report bundles found ... Check the path", telling the operator their
        correct path was wrong. It now distinguishes "nothing was there" from
        "everything was excluded".

    P1  (892) The emitted RdaResourceType echoed the OPERATOR's -ResourceType
        casing, so 'vmware' and 'VMWare' from one estate split under a
        case-sensitive downstream group. It now stamps the inventory's actual
        (canonical-by-production) key name.

    M1  (865) A consolidated bundle skipped because an extracted report sat
        beside it produced a single advisory line that named the bundle but not
        how much coverage it represented, so a one-line skip of a
        many-subscription bundle read like a trivial loss. The advisory now
        states the per-subscription report count read from the bundle's central
        directory (no extraction).

    All fixture data is invented. No real subscription, tenant, resource or
    customer identifier appears anywhere in this file.
#>

BeforeAll {
    $Script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $Script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $Script:RepoRoot 'Functions/FindResource.Functions.ps1')

    $Script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("RdaW1W2W4_{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $Script:TestRoot -Force | Out-Null

    # Writes one synthetic per-sub zip carrying an Inventory_*.json whose VMWare
    # key is spelled with the CASING passed in $KeyCasing, so a test can prove the
    # emitted RdaResourceType tracks the inventory key rather than the query.
    function Script:New-CasedPerSubZip
    {
        param(
            [Parameter(Mandatory = $true)][string]$ZipPath,
            [Parameter(Mandatory = $true)][string]$Stamp,
            [string]$KeyCasing = 'VMWare'
        )

        $Staging = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Staging -Force | Out-Null
        try
        {
            $Body = [ordered]@{ Version = '9.9.9' }
            $Body[$KeyCasing] = @(
                [ordered]@{ ID = 'invented_avsid0'; Name = 'invented_avs0'; Subscription = 'invented_sub'; ClusterSize = 3 }
            )
            $Inv = Join-Path $Staging ('Inventory_ResourcesReport_{0}.json' -f $Stamp)
            $Body | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Inv -Encoding UTF8

            if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
            Compress-Archive -Path (Join-Path $Staging '*') -DestinationPath $ZipPath -Force
        }
        finally { Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

AfterAll {
    if ($Script:TestRoot -and (Test-Path -LiteralPath $Script:TestRoot)) {
        Remove-Item -LiteralPath $Script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'W1: renamed delivery filename is still discovered' {

    It 'discovers a company-prefixed per-sub report on a recursive scan' {
        $Dir = Join-Path $Script:TestRoot 'w1-recursive'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $Dir 'CompanyName_ResourcesReport_20260101000000000ab1f.zip') -Force | Out-Null

        $Result = Get-RdaInventorySource -Path $Dir
        $Kinds = @($Result.Sources | ForEach-Object { $_.Kind })
        $Kinds | Should -Contain 'PerSubZip'
    }

    It 'accepts a company-prefixed per-sub report passed explicitly, not Rejected' {
        $File = Join-Path $Script:TestRoot 'CompanyName_ResourcesReport_20260101000000000c02e.zip'
        New-Item -ItemType File -Path $File -Force | Out-Null

        $Result = Get-RdaInventorySource -Path $File
        @($Result.Sources | ForEach-Object { $_.Kind }) | Should -Contain 'PerSubZip'
        @($Result.Rejected).Count | Should -Be 0
    }

    It 'still classifies an AllSubscriptions bundle as ConsolidatedZip, not PerSubZip' {
        $Dir = Join-Path $Script:TestRoot 'w1-bundle'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $Dir 'AllSubscriptions_ResourcesReport_20260101000000000ab1f.zip') -Force | Out-Null

        $Result = Get-RdaInventorySource -Path $Dir
        $Kinds = @($Result.Sources | ForEach-Object { $_.Kind })
        $Kinds | Should -Contain 'ConsolidatedZip'
        $Kinds | Should -Not -Contain 'PerSubZip'
    }
}

Describe 'W4: permission-denied root is Unreadable, not Missing' {

    It 'classifies a Get-Item failure as Unreadable rather than Missing' {
        $Fake = Join-Path $Script:TestRoot 'locked-root'
        New-Item -ItemType Directory -Path $Fake -Force | Out-Null

        Mock -CommandName Get-Item -MockWith { throw [System.UnauthorizedAccessException]::new('Access to the path is denied.') }

        $Result = Get-RdaInventorySource -Path $Fake
        @($Result.Missing) | Should -Not -Contain $Fake
        @($Result.Unreadable | Where-Object { $_ -like "*$Fake*" }).Count | Should -BeGreaterThan 0
    }

    It 'still classifies a genuinely absent path as Missing' {
        $Gone = Join-Path $Script:TestRoot ('no-such-{0}' -f ([guid]::NewGuid().ToString('N')))
        $Result = Get-RdaInventorySource -Path $Gone
        @($Result.Missing) | Should -Contain $Gone
    }
}

Describe 'W2: all-reads-failed is reported as read failure, not wrong causes' {

    It 'does not blame collector-absence or -Service scoping when UnitsRead is 0 but sources exist' {
        # A result with sources found but nothing read: coverage is None for the
        # requested type only because UnitsRead == 0.
        $Result = [pscustomobject]@{
            ResourceType  = @('VMWare')
            Rows          = @()
            SourceCount   = 2
            ReadCount     = 0
            UnitsRead     = 0
            UnitReadAttempts = 2
            TypePresence  = @{ 'VMWare' = 0 }
            TypeUnitIds   = @{ 'VMWare' = @() }
            Missing = @(); Unreadable = @(); Rejected = @(); Skipped = @()
            Failures = @('bundle-a.zip: corrupt', 'bundle-b.zip: corrupt')
            DuplicateUnits = @()
        }

        $Out = Write-RdaFindSummary -Result $Result 6>&1 | Out-String
        $Out | Should -Match 'NO INVENTORY WAS READ'
        $Out | Should -Not -Match 'predate'
    }
}

Describe 'D1 (875): stamp-less discovery de-dup keys on full path, not base name' {

    It 'keeps two same-named stamp-less per-sub zips in different folders as distinct sources' {
        $Root = Join-Path $Script:TestRoot ('d1-{0}' -f ([guid]::NewGuid().ToString('N')))
        $A = Join-Path $Root 'a'
        $B = Join-Path $Root 'b'
        New-Item -ItemType Directory -Path $A -Force | Out-Null
        New-Item -ItemType Directory -Path $B -Force | Out-Null
        # Same base name, no 15+ digit stamp, different folders.
        New-Item -ItemType File -Path (Join-Path $A 'ResourcesReport.zip') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $B 'ResourcesReport.zip') -Force | Out-Null

        $Result = Get-RdaInventorySource -Path $Root
        # Before the fix both collapsed to the base-name key 'ResourcesReport' and
        # one was dropped; now they key on full path and both survive.
        @($Result.Sources).Count | Should -Be 2
    }

    It 'still collapses two views of ONE stamped report to a single source' {
        $Root = Join-Path $Script:TestRoot ('d1s-{0}' -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $Stamp = '202601010000000000abc'
        # A loose json and the per-sub zip beside it, sharing one stamp.
        New-Item -ItemType File -Path (Join-Path $Root ('Inventory_ResourcesReport_{0}.json' -f $Stamp)) -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $Root ('ResourcesReport_{0}.zip' -f $Stamp)) -Force | Out-Null

        $Result = Get-RdaInventorySource -Path $Root
        @($Result.Sources).Count | Should -Be 1
    }
}

Describe 'E1 (876/805): all-excluded is not reported as a wrong path' {

    It 'does not tell the operator to check the path when every candidate was refused' {
        $Root = Join-Path $Script:TestRoot ('e1-{0}' -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        # A de-obfuscated report the PII guard refuses; it is a found-but-excluded
        # candidate, so Sources is empty for a reason that is NOT a wrong path.
        New-Item -ItemType File -Path (Join-Path $Root 'AllSubscriptions_ResourcesReport_20260101000000000_revealed.zip') -Force | Out-Null

        $Result = Find-RdaResource -Path $Root -ResourceType 'VMWare' -ThrottleLimit 2
        @($Result.Rejected).Count | Should -BeGreaterThan 0
        [int]$Result.SourceCount | Should -Be 0

        $Out = Write-RdaFindSummary -Result $Result 6>&1 | Out-String
        $Out | Should -Match 'NOTHING WAS SCANNED'
        $Out | Should -Match 'does NOT mean the path is wrong'
    }

    It 'still tells the operator to check the path when nothing at all was found' {
        $Root = Join-Path $Script:TestRoot ('e1e-{0}' -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null

        $Result = Find-RdaResource -Path $Root -ResourceType 'VMWare' -ThrottleLimit 2
        [int]$Result.SourceCount | Should -Be 0
        @($Result.Rejected).Count | Should -Be 0
        @($Result.Missing).Count | Should -Be 0

        $Out = Write-RdaFindSummary -Result $Result 6>&1 | Out-String
        $Out | Should -Match 'Check the path'
    }
}

Describe 'P1 (892): emitted RdaResourceType uses the inventory key casing, not the query' {

    It 'stamps the canonical inventory key even when the query differs in case' {
        $Dir = Join-Path $Script:TestRoot ('p1-{0}' -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Zip = Join-Path $Dir 'ResourcesReport_202601010000000000d01.zip'
        # Inventory key is 'VMWare'; the operator queries lower-case 'vmware'.
        New-CasedPerSubZip -ZipPath $Zip -Stamp '202601010000000000d01' -KeyCasing 'VMWare'

        $Result = Find-RdaResource -Path $Zip -ResourceType 'vmware' -ThrottleLimit 2
        @($Result.Rows).Count | Should -Be 1
        # The row must carry the inventory's casing, not the query's, so two
        # runs of one estate cannot split under a case-sensitive group.
        @($Result.Rows)[0].RdaResourceType | Should -BeExactly 'VMWare'
    }

    It 'still counts coverage correctly when query and key casing differ' {
        $Dir = Join-Path $Script:TestRoot ('p1c-{0}' -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Zip = Join-Path $Dir 'ResourcesReport_202601010000000000d02.zip'
        New-CasedPerSubZip -ZipPath $Zip -Stamp '202601010000000000d02' -KeyCasing 'VMWare'

        $Result = Find-RdaResource -Path $Zip -ResourceType 'vmware' -ThrottleLimit 2
        # One inventory, key present -> Full coverage for the queried type.
        (Get-RdaTypeCoverage -Result $Result)['vmware'] | Should -Be 'Full'
    }
}

Describe 'M1 (865): a skipped bundle reports how much coverage it represents' {

    It 'includes the per-subscription report count in the skip advisory' {
        # A folder holding BOTH an extracted report (Inventory_*.json) and a
        # consolidated bundle: the bundle is skipped to avoid double counting.
        # The advisory must state HOW MANY per-subscription reports the skipped
        # bundle held, so a single skip line for a many-subscription bundle is not
        # mistaken for a trivial loss.
        $Dir = Join-Path $Script:TestRoot ('m1-{0}' -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        # (a) an extracted report so the bundle is skipped, not read.
        Set-Content -LiteralPath (Join-Path $Dir 'Inventory_ResourcesReport_20260101000000000aa11.json') -Value '{ "Version": "9.9.9" }' -Encoding UTF8

        # (b) a consolidated bundle carrying 3 per-subscription report members.
        $BundleStaging = Join-Path $Script:TestRoot ('bundlestage_{0}' -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $BundleStaging -Force | Out-Null
        foreach ($N in 1..3)
        {
            Set-Content -LiteralPath (Join-Path $BundleStaging ('ResourcesReport_2026010100000000000{0}.zip' -f $N)) -Value 'x' -Encoding UTF8
        }
        $Bundle = Join-Path $Dir 'AllSubscriptions_ResourcesReport_20260101_000000.zip'
        Compress-Archive -Path (Join-Path $BundleStaging '*') -DestinationPath $Bundle -Force
        Remove-Item -LiteralPath $BundleStaging -Recurse -Force -ErrorAction SilentlyContinue

        $Result = Get-RdaInventorySource -Path $Dir
        $SkipLine = @($Result.Skipped | Where-Object { $_ -like '*AllSubscriptions_*' })[0]
        $SkipLine | Should -Not -BeNullOrEmpty -Because 'the bundle must be skipped when an extracted report sits beside it'
        $SkipLine | Should -Match 'containing 3 per-subscription report' -Because 'the skip advisory must state the coverage magnitude'
    }
}
