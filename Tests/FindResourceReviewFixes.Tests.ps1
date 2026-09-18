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

    All fixture data is invented. No real subscription, tenant, resource or
    customer identifier appears anywhere in this file.
#>

BeforeAll {
    $Script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $Script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $Script:RepoRoot 'Functions/FindResource.Functions.ps1')

    $Script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("RdaW1W2W4_{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $Script:TestRoot -Force | Out-Null
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
