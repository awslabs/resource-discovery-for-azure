# Consumption zero-record warning tests
#
# OFFLINE and self-contained: dot-sources the two pure builders and asserts the
# gate on the "consumption requested but ZERO records collected" warning. Makes
# NO Azure calls and needs no generated zip.
#
# Why this suite exists. A partner submitted a report whose Consumption CSV held
# only its header row. Nothing flagged it:
#   - The up-front access gate (Test-ConsumptionAccess) classifies the billing
#     probe's EXCEPTION text, and an empty-but-successful response raises no
#     exception, so the probe returned 'Ok'.
#   - The wrapper's console block printed NOTHING, because its condition was
#     ($Records -gt 0 -or $Failures.Count -gt 0) - excluding the exact 0/0 case
#     it existed to make loud.
#   - The shipped RunSummary.log and Diagnostics_*.log carried only a bare
#     "Consumption records collected : 0", which reads like an idle tenant.
# These tests pin the gate so that regression cannot return silently.
#
# The warning must fire ONLY when all of these hold, because each guard prevents
# a specific false positive:
#   requested (no -SkipConsumption) - a skipped phase legitimately has 0 records
#   record count == 0               - obviously
#   zero consumption failures       - a reported failure is already surfaced
#   at least one subscription ran   - a -Resume run where everything was already
#                                     completed must not claim the CSV is empty
#
# Run with: Invoke-Pester ./Tests/ConsumptionZeroRecordWarning.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent

    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1')

    # Fail loudly here rather than with a confusing "command not found" mid-test
    # if a future change renames either builder.
    foreach ($Fn in @('Get-RunSummaryLogContent', 'Write-RdaShareableDiagnosticsLog'))
    {
        if (-not (Get-Command -Name $Fn -ErrorAction SilentlyContinue))
        {
            throw "Required function '$Fn' not found after dot-sourcing."
        }
    }

    # The marker both artifacts share. Asserting on this exact phrase keeps the
    # two surfaces from drifting apart silently.
    $script:WarnMarker = 'ZERO usage records were collected'

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:DiagDir = Join-Path $TmpBase ('ConsumpWarn_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:DiagDir -Force | Out-Null
    $script:DiagPathPrefix = $script:DiagDir + [IO.Path]::DirectorySeparatorChar

    # Build a diagnostics log and return its text. $RunTag keeps each call's file
    # distinct so cases cannot read each other's output.
    function script:GetDiagText
    {
        param(
            [int]$RecordCount,
            [bool]$Requested,
            [switch]$Obfuscated,
            [string]$RunTag
        )
        $Params = @{
            DefaultPath            = $script:DiagPathPrefix
            ReportName             = 'R'
            RunDateTime            = $RunTag
            Version                = '0.0.0-test'
            PhaseTimings           = $null
            ConsumptionRecordCount = $RecordCount
            ConsumptionRequested   = $Requested
        }
        if ($Obfuscated) { $Params.Obfuscated = $true }
        $File = Write-RdaShareableDiagnosticsLog @Params
        if ([string]::IsNullOrEmpty($File) -or -not (Test-Path -LiteralPath $File))
        {
            throw 'Write-RdaShareableDiagnosticsLog did not return a written file.'
        }
        return (Get-Content -LiteralPath $File -Raw)
    }

    function script:GetSummaryText
    {
        param(
            [int]$RecordCount,
            [int]$Processed,
            $InvocationParameters = @{},
            $ConsumptionFailedSubs = @(),
            [switch]$Obfuscated
        )
        $Params = @{
            InvocationParameters   = $InvocationParameters
            Version                = '0.0.0-test'
            Processed              = $Processed
            ConsumptionRecordCount = $RecordCount
            ConsumptionFailedSubs  = $ConsumptionFailedSubs
        }
        if ($Obfuscated) { $Params.Obfuscated = $true }
        return ((Get-RunSummaryLogContent @Params) -join [Environment]::NewLine)
    }
}

AfterAll {
    if ($script:DiagDir -and (Test-Path -LiteralPath $script:DiagDir))
    {
        Remove-Item -LiteralPath $script:DiagDir -Recurse -Force
    }
}

Describe 'RunSummary.log consumption zero-record warning' {

    It 'Warns when consumption was requested, 0 records, no failures, and a subscription ran' {
        # The exact partner signature.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1
        $Text | Should -Match $script:WarnMarker
    }

    It 'Always reports the record count in the Health block' {
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1
        $Text | Should -Match 'Consumption records collected\s*:\s*0'
    }

    It 'Stays silent when -SkipConsumption was passed as a switch' {
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -InvocationParameters @{ SkipConsumption = [switch]$true }
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Stays silent when -SkipConsumption was passed as a bool' {
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -InvocationParameters @{ SkipConsumption = $true }
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Still warns when SkipConsumption is present but explicitly false' {
        # -SkipConsumption:$false means consumption WAS requested.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -InvocationParameters @{ SkipConsumption = [switch]$false }
        $Text | Should -Match $script:WarnMarker
    }

    It 'Stays silent when no subscription actually ran (resume with nothing to do)' {
        # Guards the false positive where a prior pass already produced populated
        # CSVs and this invocation processed nothing.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 0
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Stays silent when records were collected' {
        $Text = script:GetSummaryText -RecordCount 42 -Processed 1
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Stays silent when a consumption failure was already reported' {
        # A reported failure is surfaced by its own block; warning too would
        # double-report and misattribute the cause.
        $Failed = @([pscustomobject]@{ Name = 'x'; Id = 'y'; Message = 'boom' })
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -ConsumptionFailedSubs $Failed
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Emits the warning in an obfuscated run too' {
        # Obfuscated bundles are the ones normally shared, so this is the case
        # that actually reaches a report consumer.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -Obfuscated
        $Text | Should -Match $script:WarnMarker
    }

    It 'Names the CSP cost-visibility cause and does not claim RBAC will fix it' {
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1
        $Text | Should -Match 'CSP'
        $Text | Should -Match 'Partner Center'
        $Text | Should -Match 'not'
    }

    It 'Carries no identifier of its own (safe for an obfuscated bundle)' {
        # The warning text must be static guidance. A GUID here would leak.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -Obfuscated
        $Text | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    }
}

Describe 'Diagnostics_*.log consumption zero-record warning' {

    It 'Warns when consumption was requested, 0 records, and no failures' {
        $Text = script:GetDiagText -RecordCount 0 -Requested $true -RunTag 'd1'
        $Text | Should -Match $script:WarnMarker
    }

    It 'Reports the record count when consumption was requested' {
        $Text = script:GetDiagText -RecordCount 12 -Requested $true -RunTag 'd2'
        $Text | Should -Match 'Consumption records collected:\s*12'
    }

    It 'Stays silent and reports n/a when -SkipConsumption was passed' {
        $Text = script:GetDiagText -RecordCount 0 -Requested $false -RunTag 'd3'
        $Text | Should -Match 'n/a'
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Stays silent when records were collected' {
        $Text = script:GetDiagText -RecordCount 46 -Requested $true -RunTag 'd4'
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Emits the warning in the OBFUSCATED diagnostics log' {
        # This is the surface that made the partner case undiagnosable.
        $Text = script:GetDiagText -RecordCount 0 -Requested $true -Obfuscated -RunTag 'd5'
        $Text | Should -Match $script:WarnMarker
    }

    It 'Declares the run mode in the first five lines so consumers can detect it' {
        # Tests/OutputCompleteness.Tests.ps1 derives bundle mode from this header
        # within a 5-line window; if that contract breaks, its DebugLog rule
        # silently falls back to the stricter branch.
        $Obf = (script:GetDiagText -RecordCount 0 -Requested $true -Obfuscated -RunTag 'd6') -split "`r?`n"
        $Def = (script:GetDiagText -RecordCount 0 -Requested $true -RunTag 'd7') -split "`r?`n"
        (($Def | Select-Object -First 5) -join ' ') | Should -Match 'non-obfuscated'
        (($Obf | Select-Object -First 5) -join ' ') | Should -Not -Match 'non-obfuscated'
    }
}

Describe 'The two surfaces agree' {

    It 'Uses the same marker phrase in RunSummary.log and Diagnostics_*.log' {
        # Prevents one surface being reworded and the other left behind.
        $Summary = script:GetSummaryText -RecordCount 0 -Processed 1
        $Diag = script:GetDiagText -RecordCount 0 -Requested $true -RunTag 'a1'
        $Summary | Should -Match $script:WarnMarker
        $Diag | Should -Match $script:WarnMarker
    }

    It 'Does not describe the query window as UTC (the consumption phase uses host local time)' {
        # ResourceInventory.ps1's consumption phase uses (Get-Date).AddDays(...).Date
        # - LOCAL midnight. Only the access PROBE was moved to UTC midnight. Saying
        # "UTC" here would be a factual error about the window actually queried.
        $Summary = script:GetSummaryText -RecordCount 0 -Processed 1
        $Diag = script:GetDiagText -RecordCount 0 -Requested $true -RunTag 'a2'
        $Summary | Should -Not -Match 'midnight UTC'
        $Diag | Should -Not -Match 'midnight UTC'
    }
}
