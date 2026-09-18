# Requires -Modules Pester
# -MetricsDetailed: the default sampling grain is hourly for the VM/SQL/OSS-DB series and disk I/O (upstream
# awslabs parity, 4x fewer VM data points); the switch restores each family's native cadence; an explicit
# -MetricsIntervalMinutes still wins for VM/SQL/OSS-DB and never touches disk I/O. Offline: the rule is a pure
# function (Get-RdaMetricGrainPlan) extracted by AST, plus source guards on the definitions and forwarding.

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:MetricsSrc = Get-Content -LiteralPath (Join-Path $script:Repo 'Extension/Metrics.ps1') -Raw
    $Tokens = $null; $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseInput($script:MetricsSrc, [ref]$Tokens, [ref]$Errors)
    $FnAst = $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-RdaMetricGrainPlan' }, $true) | Select-Object -First 1
    if (-not $FnAst) { throw 'Get-RdaMetricGrainPlan was not found in Extension/Metrics.ps1' }
    . ([scriptblock]::Create($FnAst.Extent.Text))
}

Describe 'Get-RdaMetricGrainPlan - precedence' {
    It 'defaults to hourly for VM, SQL, OSS-DB and disk I/O (upstream parity)' {
        $G = Get-RdaMetricGrainPlan
        $G.Vm | Should -Be '01:00:00'; $G.Sql | Should -Be '01:00:00'; $G.Db | Should -Be '01:00:00'; $G.Disk | Should -Be '01:00:00'
    }
    It '-MetricsDetailed restores the native cadences: VM/disk 15 min, SQL 30 min, OSS-DB 60 min' {
        $G = Get-RdaMetricGrainPlan -MetricsDetailed
        $G.Vm | Should -Be '00:15:00'; $G.Sql | Should -Be '00:30:00'; $G.Db | Should -Be '01:00:00'; $G.Disk | Should -Be '00:15:00'
    }
    It 'an explicit -MetricsIntervalMinutes applies uniformly to VM/SQL/OSS-DB and beats -MetricsDetailed' {
        $G = Get-RdaMetricGrainPlan -MetricsIntervalMinutes 5 -MetricsDetailed
        $G.Vm | Should -Be '00:05:00'; $G.Sql | Should -Be '00:05:00'; $G.Db | Should -Be '00:05:00'
    }
    It '-MetricsIntervalMinutes never changes disk I/O; only -MetricsDetailed does' {
        (Get-RdaMetricGrainPlan -MetricsIntervalMinutes 5).Disk | Should -Be '01:00:00'
        (Get-RdaMetricGrainPlan -MetricsIntervalMinutes 5 -MetricsDetailed).Disk | Should -Be '00:15:00'
    }
    It 'honours a coarser explicit value as-is even when it exceeds a native cadence (operator choice)' {
        (Get-RdaMetricGrainPlan -MetricsIntervalMinutes 30).Db | Should -Be '00:30:00'
    }
}

Describe '-MetricsDetailed is wired through' {
    It 'Metrics.ps1 declares the switch and takes every sampled interval from the plan' {
        $script:MetricsSrc | Should -Match '\[switch\]\$MetricsDetailed'
        $script:MetricsSrc | Should -Match 'Get-RdaMetricGrainPlan -MetricsIntervalMinutes \$MetricsIntervalMinutes -MetricsDetailed:\$MetricsDetailed'
        ([regex]::Matches($script:MetricsSrc, "Composite Disk [^\n]*Interval = \`$DiskMetricInterval")).Count | Should -Be 4 -Because 'all four disk I/O definitions must follow the plan'
        $script:MetricsSrc | Should -Not -Match "Composite Disk [^\n]*Interval = '00:15:00'"
    }
    It 'ResourceInventory.ps1 declares it and forwards it to Extension/Metrics.ps1' {
        $Src = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'ResourceInventory.ps1')
        $Src | Should -Match '\[switch\]\$MetricsDetailed'
        $Src | Should -Match '-MetricsDetailed:\$MetricsDetailed'
    }
    It 'Run-AllSubscriptions.ps1 declares it and forwards it on the direct, worker and stream paths' {
        $Src = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.ps1')
        $Src | Should -Match '\[switch\]\$MetricsDetailed'
        $Src | Should -Match "if \(\`$MetricsDetailed\) \{ \`$ExtraFlags \+= '-MetricsDetailed' \}"
        $Src | Should -Match "if \(\`$MetricsDetailed\) \{ \`$InventoryPassthrough\['MetricsDetailed'\] = \`$true \}"
        $Src | Should -Match 'if \(\$MetricsDetailed\) \{ \$WorkerArgs\.MetricsDetailed = \$true \}'
    }
    It 'Run-AllSubscriptions.Stream.ps1 declares it and forwards it' {
        $Src = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.Stream.ps1')
        $Src | Should -Match '\[switch\] \$MetricsDetailed'
        $Src | Should -Match "if \(\`$MetricsDetailed\) \{ \`$InventoryPassthrough\['MetricsDetailed'\] = \`$true \}"
    }
    It 'README documents the switch and the hourly default' {
        $Readme = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'README.md')
        $Readme | Should -Match '`MetricsDetailed`'
        $Readme | Should -Match 'default grain is \*\*hourly\*\*'
    }
}
