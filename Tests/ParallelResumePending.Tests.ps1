# Run-AllSubscriptions.ps1, parallel path: on -Resume the subscriptions an
# earlier run completed are left out before the streams are counted and
# sliced. A stream knows only its own per-stream state file, which the
# end-of-run merge folds in and deletes, so it would collect them again.
#
# The pending-list loop is taken from the parallel path of the wrapper's parsed
# source and run as written; the slicing after it reads only that list.
#
# Run with: Invoke-Pester ./Tests/ParallelResumePending.Tests.ps1 -Output Detailed

BeforeAll {
    $Path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $SeqIf = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq '$ParallelStreams -le 1' }, $true))
    $script:Else = $SeqIf[0].ElseClause
    $script:Loop = @($script:Else.Statements | Where-Object { $_ -is [System.Management.Automation.Language.ForEachStatementAst] -and $_.Body.Extent.Text.Contains('$PendingSubscriptions += $Sub') })
}

Describe 'The parallel path on -Resume' {
    It 'has one pending-list loop, and slices only that list' {
        $script:Loop.Count | Should -Be 1
        $Text = $script:Else.Extent.Text
        $Text | Should -Match ([regex]::Escape('$StreamCount = [Math]::Min($ParallelStreams, $PendingSubscriptions.Count)'))
        $Text | Should -Match ([regex]::Escape('$Slices[$i % $StreamCount].Add($PendingSubscriptions[$i])'))
        $Text | Should -Not -Match ([regex]::Escape('.Add($Subscriptions[$i])'))
    }

    It 'leaves out the completed subscriptions on -Resume and records them as skipped (<Label>)' -ForEach @(
        @{ Label = '-Resume'; Resume = $true; Pending = @('sub-c'); Skipped = @('sub-a', 'sub-b') }
        @{ Label = 'no -Resume'; Resume = $false; Pending = @('sub-a', 'sub-b', 'sub-c'); Skipped = @() }
    ) {
        $Subscriptions = @('sub-a', 'sub-b', 'sub-c' | ForEach-Object { [pscustomobject]@{ Id = $_; Name = $_ } })
        $CompletedIds = @('sub-a', 'sub-b')
        $SkippedCount = 0
        $SkippedSubscriptions = @()
        $PendingSubscriptions = @()
        $null = $Subscriptions, $CompletedIds, $Resume
        . ([scriptblock]::Create($script:Loop[0].Extent.Text)) 6>$null
        @($PendingSubscriptions | ForEach-Object Id) | Should -Be $Pending
        @($SkippedSubscriptions | ForEach-Object Id) | Should -Be $Skipped
        $SkippedCount | Should -Be $Skipped.Count
    }
}
