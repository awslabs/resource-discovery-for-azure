# Health lists of a direct run repeated in one PowerShell session
# Run with: Invoke-Pester ./Tests/DirectRunHealthListReset.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# ResourceInventory.ps1 keeps its collector, metrics and consumption failures
# in session-wide lists ($Global:CollectorFailures, $Global:MetricsFailedSubs,
# $Global:ConsumptionFailedSubs and $Global:ConsumptionRecordCount). It set
# them only when they were empty, so a second direct run in the same session
# kept the first run's failures, and its diagnostics log named a failure the
# second run never had. A direct run now starts them empty. Under -RunAllSubs
# Run-AllSubscriptions.ps1 owns the lists and empties them once at its own
# start, so an inner run must keep what the wrapper has gathered.
#
# The test copies the scripts to a temp folder and runs the REAL
# ResourceInventory.ps1 in a child pwsh (Tests/Helpers/InnerRunHarness.ps1)
# against offline stand-ins. Placeholder ids only; no live Azure.
#
# Not run on Windows: the harness's stand-ins are written for the Unix paths.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Harness = Join-Path $PSScriptRoot 'Helpers/InnerRunHarness.ps1'
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('DirectRunHealthListReset_' + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    $null = New-Item -ItemType Directory -Path $script:Tree -Force
    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    function Invoke-HarnessRuns
    {
        param([string[]]$Extra)
        $Out = Join-Path $script:WorkDir ('out_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $Out -Force
        $Lists = Join-Path $Out 'lists'
        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Out', ($Out + '/'), '-ListsOut', $Lists) + $Extra
        $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Console = $Console; Out = $Out; Lists = $Lists }
    }

    function Get-RunLists([string]$Lists, [int]$Run)
    {
        Get-Content -LiteralPath ('{0}-{1}.json' -f $Lists, $Run) -Raw | ConvertFrom-Json
    }

    function Get-RunDiagnostics([string]$Out, [int]$Run)
    {
        $File = @(Get-ChildItem -LiteralPath (Join-Path $Out ('run{0}' -f $Run)) -Filter 'Diagnostics_*.log' -File)
        $File.Count | Should -Be 1 -Because ('run {0} writes one diagnostics log' -f $Run)
        Get-Content -LiteralPath $File[0].FullName -Raw
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Two direct runs in one session' -Skip:$IsWindows {
    BeforeAll {
        $script:Run = Invoke-HarnessRuns -Extra @('-Runs', '2', '-FailFirstRunConsumption')
    }

    It 'the first run records its consumption failure' {
        $First = Get-RunLists $script:Run.Lists 1
        @($First.ConsumptionFailedSubs).Count | Should -Be 1 -Because $script:Run.Console
        @($First.ConsumptionFailedSubs)[0].Message | Should -Match 'stand-in: the usage query failed'
        Get-RunDiagnostics $script:Run.Out 1 | Should -Match 'Consumption failed/incomplete subscriptions: 1'
    }

    It 'the second, clean run does not keep the first run''s failure' {
        $Second = Get-RunLists $script:Run.Lists 2
        @($Second.ConsumptionFailedSubs).Count | Should -Be 0 -Because ($Second | ConvertTo-Json -Depth 5)
        @($Second.CollectorFailures).Count | Should -Be 0
        @($Second.MetricsFailedSubs).Count | Should -Be 0
        $Second.ConsumptionRecordCount | Should -Be 1 -Because 'only the second run''s one usage row counts'
    }

    It 'the second run''s diagnostics log names no failure' {
        $Diag = Get-RunDiagnostics $script:Run.Out 2
        $Diag | Should -Match 'Consumption failed/incomplete subscriptions: 0'
        $Diag | Should -Not -Match 'stand-in: the usage query failed'
    }

    It 'the second run finishes with exit 0' {
        $script:Run.Exit | Should -Be 0 -Because $script:Run.Console
    }
}

Describe 'An inner run under -RunAllSubs' -Skip:$IsWindows {
    BeforeAll {
        $script:Run = Invoke-HarnessRuns -Extra @('-RunAllSubs')
    }

    It 'keeps what the wrapper gathered before it and adds its own' {
        $Lists = Get-RunLists $script:Run.Lists 1
        @($Lists.CollectorFailures | Where-Object { $_.Id -eq 'wrapper-entry' }).Count | Should -Be 1 -Because $script:Run.Console
        @($Lists.MetricsFailedSubs | Where-Object { $_.Id -eq 'wrapper-entry' }).Count | Should -Be 1
        @($Lists.ConsumptionFailedSubs | Where-Object { $_.Id -eq 'wrapper-entry' }).Count | Should -Be 1
        $Lists.ConsumptionRecordCount | Should -Be 8 -Because 'the wrapper''s 7 plus this run''s one usage row'
    }
}
