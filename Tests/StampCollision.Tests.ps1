#Requires -Version 7.0
<#
    Reproduction + regression coverage for the report-stamp collision.

    The producer (ResourceInventory.ps1) builds a report stamp as
    yyyyMMddHHmmssfff (17 digits) + a 4-char hex per-process discriminator, so two
    parallel workers that hit the same millisecond emit names that differ ONLY in
    the hex tail, e.g. ResourcesReport_20260101000000000ab1f.zip vs
    ResourcesReport_20260101000000000c02e.zip.

    Get-RdaReportId once keyed on '(\d{15,})', which captured only the leading digit
    run and so returned the SAME key for both. Get-RdaInventorySource then grouped on
    that key and kept one member per group, dropping the other WITHOUT recording it
    in Missing/Unreadable/Rejected/Skipped - a silent loss of one subscription. The
    key now includes the hex tail.

    All fixture data is invented. No real subscription, tenant, resource or
    customer identifier appears anywhere in this file.
#>

BeforeAll {
    $Script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $Script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $Script:RepoRoot 'Functions/FindResource.Functions.ps1')

    # Two same-millisecond stamps that differ only in the 4-char hex discriminator.
    $Script:StampMillis = '20260101000000000'   # 17 digits
    $Script:NameA = "ResourcesReport_${StampMillis}ab1f.zip"
    $Script:NameB = "ResourcesReport_${StampMillis}c02e.zip"

    $Script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("RdaStampCollision_{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $Script:TestRoot -Force | Out-Null

    # Discovery classifies PerSubZip by NAME and does not open the archive, so an
    # empty file under each name is a sufficient, valid two-source fixture.
    New-Item -ItemType File -Path (Join-Path $Script:TestRoot $Script:NameA) -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $Script:TestRoot $Script:NameB) -Force | Out-Null
}

AfterAll {
    if ($Script:TestRoot -and (Test-Path -LiteralPath $Script:TestRoot))
    {
        Remove-Item -LiteralPath $Script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Report-stamp collision on same-millisecond reports' {

    It 'Get-RdaReportId must give DIFFERENT keys to two reports that differ only in the hex discriminator' {
        $IdA = Get-RdaReportId -Name $Script:NameA
        $IdB = Get-RdaReportId -Name $Script:NameB
        # These are two distinct subscriptions' reports; their keys must differ.
        $IdA | Should -Not -Be $IdB
    }

    It 'Get-RdaInventorySource must not silently drop the colliding second report' {
        $Result = Get-RdaInventorySource -Path $Script:TestRoot

        $SourceFiles = @($Result.Sources | ForEach-Object { [System.IO.Path]::GetFileName($_.File) })
        $AccountedElsewhere = @($Result.Missing) + @($Result.Unreadable) + @($Result.Rejected) + @($Result.Skipped)

        # Both reports must be reachable: either both survive as sources, or a
        # dropped one is explicitly recorded somewhere. Neither may vanish.
        foreach ($Name in @($Script:NameA, $Script:NameB))
        {
            $InSources = $SourceFiles -contains $Name
            $Recorded = @($AccountedElsewhere | Where-Object { $_ -like "*$Name*" }).Count -gt 0
            ($InSources -or $Recorded) | Should -BeTrue -Because "$Name must not disappear without a trace"
        }
    }
}

Describe 'Report-stamp tail when parallel streams share one process' {
    # Under -StreamIsolation Runspace the streams are runspaces of ONE process, so the PID alone no longer
    # tells two same-millisecond reports apart. The statement is lifted from ResourceInventory.ps1 and run,
    # with the process id and the runspace id as inputs.
    BeforeAll {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Script:RepoRoot 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Assign = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$ProcDiscriminator' }, $true))
        if ($Assign.Count -ne 1) { throw ('expected one $ProcDiscriminator assignment in ResourceInventory.ps1, found {0}' -f $Assign.Count) }
        $Script:TailText = $Assign[0].Right.Extent.Text
        $Parameterised = ($Script:TailText -replace '\$PID\b', '$$ProcessId') -replace '\[runspace\]::DefaultRunspace\.Id', '$$RunspaceId'
        $Script:TailOf = [scriptblock]::Create('param($ProcessId, $RunspaceId) ' + $Parameterised)
    }

    It 'keeps the plain PID value in the first runspace of a process (a standalone run, the sequential wrapper, a stream process)' {
        foreach ($ProcessId in 1, 4242, 70000, 123456)
        {
            (& $Script:TailOf $ProcessId 1) | Should -Be ('{0:x4}' -f ($ProcessId -band 0xffff))
        }
    }

    It 'gives every runspace of one process its own 4-hex tail' {
        $Tails = @(1..2000 | ForEach-Object { & $Script:TailOf 4242 $_ })
        @($Tails | Where-Object { $_ -cnotmatch '^[0-9a-f]{4}$' }).Count | Should -Be 0
        @($Tails | Select-Object -Unique).Count | Should -Be 2000
    }

    It 'differs between thread jobs running at the same time in one process' {
        $Jobs = @(1..3 | ForEach-Object { Start-ThreadJob -ThrottleLimit 3 -ArgumentList $Script:TailText -ScriptBlock { param($Expression) [pscustomobject]@{ ProcessId = $PID; Tail = (& ([scriptblock]::Create($Expression))) } } })
        $Seen = @(Receive-Job -Job $Jobs -Wait -AutoRemoveJob)
        @($Seen.ProcessId | Select-Object -Unique).Count | Should -Be 1
        @($Seen.Tail | Select-Object -Unique).Count | Should -Be 3
    }
}
