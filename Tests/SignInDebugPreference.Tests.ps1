# Debug output after the script signs in by itself
# Run with: Invoke-Pester ./Tests/SignInDebugPreference.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# With no saved sign-in and no -TenantID the script signs in itself. It turned
# debug output off for the sign-in and then set $DebugPreference to
# 'Continue', not back to what it was, so every Az cmdlet the sign-in step ran
# afterwards (the subscription list, the tenant choice) printed DEBUG lines in
# a run without -Debug. The script now puts the earlier value back.
#
# The test copies the scripts to a temp folder and runs the REAL
# ResourceInventory.ps1 in a child pwsh (Tests/Helpers/InnerRunHarness.ps1)
# against offline stand-ins whose Get-AzSubscription writes one debug line.
# Cases: the script signs in itself (-DeviceLogin) without and with -Debug,
# and a run that reuses the saved sign-in, each under en-US and tr-TR.
# Placeholder ids only; no live Azure.
#
# Not run on Windows: the harness's stand-ins are written for the Unix paths.

BeforeDiscovery {
    $script:Cases = @(
        foreach ($Culture in @('en-US', 'tr-TR'))
        {
            @{ Culture = $Culture; SignInFirst = $true; DebugOutput = $false; Expect = $false; Name = 'signs in itself' }
            @{ Culture = $Culture; SignInFirst = $true; DebugOutput = $true; Expect = $true; Name = 'signs in itself, with -Debug' }
            @{ Culture = $Culture; SignInFirst = $false; DebugOutput = $false; Expect = $false; Name = 'reuses the saved sign-in' }
        }
    )
}

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Harness = Join-Path $PSScriptRoot 'Helpers/InnerRunHarness.ps1'
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('SignInDebugPreference_' + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    $null = New-Item -ItemType Directory -Path $script:Tree -Force
    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    function Invoke-SignInRun
    {
        param([string]$Culture, [bool]$SignInFirst, [bool]$DebugOutput)
        $Out = Join-Path $script:WorkDir ('out_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $Out -Force
        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Out', $Out, '-Culture', $Culture)
        if ($SignInFirst) { $ArgList += '-SignInFirst' }
        if ($DebugOutput) { $ArgList += '-DebugOutput' }
        $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Console = $Console }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Direct run under <Culture> that <Name>' -ForEach $script:Cases -Skip:$IsWindows {
    BeforeAll {
        $script:Run = Invoke-SignInRun -Culture $Culture -SignInFirst $SignInFirst -DebugOutput $DebugOutput
    }

    It 'finishes with exit 0' {
        $script:Run.Exit | Should -Be 0 -Because ($script:Run.Console -join "`n")
    }

    It 'signs in itself only when there is no saved sign-in' {
        @($script:Run.Console | Where-Object { $_ -like '*Calling Login, using device login.*' }).Count | Should -Be $(if ($SignInFirst) { 1 } else { 0 })
    }

    It 'prints the subscription list''s debug line only under -Debug' {
        $Lines = @($script:Run.Console | Where-Object { $_ -like '*DEBUG: stand-in debug line*' })
        if ($Expect) { $Lines.Count | Should -BeGreaterThan 0 } else { $Lines.Count | Should -Be 0 -Because ($Lines -join "`n") }
    }
}
