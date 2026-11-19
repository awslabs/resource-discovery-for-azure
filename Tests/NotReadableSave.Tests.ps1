#Requires -Modules Pester
# Save-CompletedSubscriptionIds keeps the not-readable list a run gave for the
# same file, so a later save puts it right when the access check's own save did
# not reach the disk (sync/pr-68).

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('NotReadableSave_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
}

AfterAll {
    Remove-Item -LiteralPath $script:TestBase -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'A save after the access check''s own save did not reach the disk' {
    It 'writes the not-readable list this run gave, so clearing the failed-save flag is right' {
        Mock Write-Host { }
        $Root = Join-Path $script:TestBase ('notreadable-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $Path = Join-Path $Root '.resume-state-t.json'
        Save-CompletedSubscriptionIds -Path $Path -Tenant 't' -Ids @('sub-a') -FailedAttempts @() -Reports @() -NotReadable @()
        $script:FailWrites = $true
        Mock Set-Content -ParameterFilter { $script:FailWrites -and [string]$LiteralPath -like '*.tmp' } -MockWith { throw 'stand-in: disk full' }
        Save-CompletedSubscriptionIds -Path $Path -Tenant 't' -Ids @('sub-a') -FailedAttempts @() -Reports @() -NotReadable @('sub-x')
        @(Get-NotReadableSubscriptionIds -Path $Path -Tenant 't') | Should -BeNullOrEmpty -Because 'that save did not reach the disk'
        $script:FailWrites = $false
        $script:ResumeStateSaveFailed = $true
        Save-CompletedSubscriptionIds -Path $Path -Tenant 't' -Ids @('sub-a', 'sub-b') -FailedAttempts @() -Reports @()
        @(Get-NotReadableSubscriptionIds -Path $Path -Tenant 't') | Should -Be @('sub-x')
        $script:ResumeStateSaveFailed | Should -BeFalse
        Remove-Variable -Name RdaNotReadableForState -Scope Script -ErrorAction SilentlyContinue
    }
}
