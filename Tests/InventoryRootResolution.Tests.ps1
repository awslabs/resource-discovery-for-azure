# OFFLINE unit tests for Get-RdaInventoryRoot, the single resolver for the output root (no Azure/zip/env).
# Pins the two easily-regressed properties: an explicit -OutputDirectory is NEVER redirected, and an empty $HOME never degrades to the filesystem root.

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ("RdaRootTests_" + [guid]::NewGuid().ToString('N'))
    New-Item -Path $script:Sandbox -ItemType Directory -Force | Out-Null

    # Saved so the suite cannot leak state into the rest of the run.
    $script:SavedPin = $env:RDA_INVENTORY_ROOT
    $env:RDA_INVENTORY_ROOT = $null
}

AfterAll {
    $env:RDA_INVENTORY_ROOT = $script:SavedPin
    if ($script:Sandbox -and (Test-Path $script:Sandbox))
    {
        Get-ChildItem -Path $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.Attributes = 'Normal' } catch { Write-Verbose 'attr reset skipped' } }
        Remove-Item -Path $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RdaInventoryRoot: explicit -OutputDirectory' {

    It 'creates a path that does not exist yet and reports Explicit' {
        $Target = Join-Path $script:Sandbox 'brand-new/nested/deep'
        Test-Path $Target | Should -BeFalse -Because 'the point is that it does not exist yet'

        $R = Get-RdaInventoryRoot -Requested $Target -NoInherit
        $R.Ok | Should -BeTrue
        $R.Source | Should -Be 'Explicit'
        $R.IsFallback | Should -BeFalse
        Test-Path -LiteralPath $R.Path -PathType Container | Should -BeTrue -Because 'nested parents must be created too'
    }

    It 'leaves no probe files behind' {
        $Target = Join-Path $script:Sandbox 'no-litter'
        $R = Get-RdaInventoryRoot -Requested $Target -NoInherit
        $R.Ok | Should -BeTrue
        @(Get-ChildItem -LiteralPath $R.Path -Force -Filter '.rda-root-probe-*').Count | Should -Be 0
    }

    It 'strips a trailing separator so callers can append predictably' {
        $Target = (Join-Path $script:Sandbox 'trailing') + [IO.Path]::DirectorySeparatorChar
        $R = Get-RdaInventoryRoot -Requested $Target -NoInherit
        $R.Path | Should -Not -Match ([regex]::Escape([string][IO.Path]::DirectorySeparatorChar) + '$')
    }

    # THE most important assertion in this file. An operator who named a location
    # named it deliberately - very often a mount they intend to collect onto.
    # Silently writing somewhere else is worse than failing.
    It 'FAILS rather than silently redirecting when the explicit path is unwritable' {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'chmod-based read-only setup is POSIX-only'; return }
        if ((& id -u) -eq 0) { Set-ItResult -Skipped -Because 'chmod 500 does not deny writes to root (common in CI containers), so the resolver would stay writable and the failure expectation would be spurious'; return }

        $Ro = Join-Path $script:Sandbox 'readonly-explicit'
        New-Item -Path $Ro -ItemType Directory -Force | Out-Null
        & /bin/chmod 500 $Ro
        try
        {
            $R = Get-RdaInventoryRoot -Requested $Ro -NoInherit
            $R.Ok | Should -BeFalse -Because 'an unusable EXPLICIT path must not fall back'
            $R.IsFallback | Should -BeFalse
            $R.Message | Should -Match 'not usable'
            $R.Message | Should -Match 'writable'
        }
        finally { & /bin/chmod 700 $Ro }
    }
}

Describe 'Get-RdaInventoryRoot: default location' {

    It 'uses the per-user default and does not report a fallback on a normal machine' {
        $R = Get-RdaInventoryRoot -NoInherit
        $R.Ok | Should -BeTrue
        $R.Source | Should -Be 'Default'
        $R.IsFallback | Should -BeFalse
        $R.Path | Should -Match 'InventoryReports$'
    }

    It 'is deterministic - two calls in the same environment agree' {
        # This is what allowed the wrapper and the inner script to be given
        # separate resolver calls without their outputs diverging.
        (Get-RdaInventoryRoot -NoInherit).Path | Should -Be (Get-RdaInventoryRoot -NoInherit).Path
    }

    It 'never returns the filesystem root when HOME is empty' {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'the HOME branch is the Unix branch'; return }

        $SavedHome = $HOME
        $SavedEnvHome = $env:HOME
        try
        {
            Set-Variable -Name HOME -Scope Global -Value '' -Force
            $env:HOME = ''

            $R = Get-RdaInventoryRoot -NoInherit
            $R.Ok | Should -BeTrue -Because 'an empty HOME must still yield a working location'
            # The regression: "$HOME/InventoryReports" with an empty HOME produced
            # the literal '/InventoryReports', which a normal user cannot create.
            $R.Path | Should -Not -Be '/InventoryReports'
            $R.Path | Should -Not -Match '^/InventoryReports'
            $R.Source | Should -Be 'Default' -Because 'temp becomes the FIRST candidate when HOME is unusable, so it is not a degraded choice'
        }
        finally
        {
            Set-Variable -Name HOME -Scope Global -Value $SavedHome -Force
            $env:HOME = $SavedEnvHome
        }
    }
}

Describe 'Get-RdaInventoryRoot: child-process agreement' {

    It 'honours a pinned root so stream workers match their parent' {
        $Pinned = Join-Path $script:Sandbox 'pinned-root'
        New-Item -Path $Pinned -ItemType Directory -Force | Out-Null
        Set-RdaInventoryRootForChildren -Path $Pinned
        try
        {
            $R = Get-RdaInventoryRoot
            $R.Ok | Should -BeTrue
            $R.Path | Should -Be $Pinned
            $R.Source | Should -Be 'Inherited'
        }
        finally { $env:RDA_INVENTORY_ROOT = $null }
    }

    It 're-probes instead of failing when the pinned value is stale' {
        # The stale pin must be unusable WITHOUT relying on privilege (a filesystem-root
        # path is creatable by root/ACL), so pin a path UNDER A FILE - no OS can mkdir there. Pin the child, not the file, to avoid -Force clobber, and keep it in $script:Sandbox for cleanup.
        $Blocker = Join-Path $script:Sandbox 'blocker-file'
        Set-Content -LiteralPath $Blocker -Value 'not a directory' -Encoding utf8
        Set-RdaInventoryRootForChildren -Path (Join-Path $Blocker 'child')
        try
        {
            $R = Get-RdaInventoryRoot
            $R.Ok | Should -BeTrue -Because 'a stale pin must be ignored, not fatal'
            $R.Source | Should -Not -Be 'Inherited'
            $R.Path | Should -Not -Match ([regex]::Escape($Blocker)) -Because 'the re-probe must land elsewhere entirely, not inside the unusable pin'
            # The Source/Path assertions only prove the pin was REJECTED. Assert the
            # re-probe actually produced a usable directory too, so a future change
            # cannot satisfy this case by falling through to something unusable.
            # Deliberately not asserting Source -eq 'Default': a locked-down host may
            # legitimately answer 'Fallback', which would make that brittle.
            Test-Path -LiteralPath $R.Path -PathType Container | Should -BeTrue -Because 'the re-probe must yield a root that actually exists'
        }
        finally { $env:RDA_INVENTORY_ROOT = $null }
    }

    It 'an explicit request outranks a pinned root' {
        $Pinned = Join-Path $script:Sandbox 'pinned-loses'
        $Explicit = Join-Path $script:Sandbox 'explicit-wins'
        New-Item -Path $Pinned -ItemType Directory -Force | Out-Null
        Set-RdaInventoryRootForChildren -Path $Pinned
        try
        {
            $R = Get-RdaInventoryRoot -Requested $Explicit
            $R.Path | Should -Be $Explicit
            $R.Source | Should -Be 'Explicit'
        }
        finally { $env:RDA_INVENTORY_ROOT = $null }
    }
}

Describe 'Get-RdaInventoryRoot: degraded default falls back loudly' {

    It 'falls back to temp and names where the output went' {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'chmod-based read-only setup is POSIX-only'; return }
        if ((& id -u) -eq 0) { Set-ItResult -Skipped -Because 'chmod 500 does not deny writes to root (common in CI containers), so the preferred candidate would stay creatable and no fallback would occur'; return }

        # Point HOME at a read-only directory so the preferred candidate
        # ($HOME/InventoryReports) cannot be created, leaving temp as the fallback.
        $RoHome = Join-Path $script:Sandbox 'readonly-home'
        New-Item -Path $RoHome -ItemType Directory -Force | Out-Null
        & /bin/chmod 500 $RoHome

        $SavedHome = $HOME
        $SavedEnvHome = $env:HOME
        try
        {
            Set-Variable -Name HOME -Scope Global -Value $RoHome -Force
            $env:HOME = $RoHome

            $R = Get-RdaInventoryRoot -NoInherit
            $R.Ok | Should -BeTrue -Because 'the run must still be able to produce a report'
            $R.IsFallback | Should -BeTrue
            $R.Source | Should -Be 'Fallback'
            $R.Path | Should -Not -Match ([regex]::Escape($RoHome))
            $R.Message | Should -Match 'not usable'
            $R.Message | Should -Match ([regex]::Escape($R.Path)) -Because 'the operator must be told where the output actually went'
            $R.Message | Should -Match '-OutputDirectory' -Because 'and how to choose it themselves'
            Test-Path -LiteralPath $R.Path -PathType Container | Should -BeTrue
        }
        finally
        {
            Set-Variable -Name HOME -Scope Global -Value $SavedHome -Force
            $env:HOME = $SavedEnvHome
            & /bin/chmod 700 $RoHome
        }
    }
}

Describe 'Output-root wiring (source guards)' {

    BeforeAll {
        $script:InvPath = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
        $script:InvSrc = Get-Content -LiteralPath $script:InvPath -Raw
        $script:WrapSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $script:StreamSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1') -Raw
    }

    # The root was computed inline in SIX places. Any one of them left behind would
    # silently ignore a fallback and desynchronise the wrapper from the inner script.
    It 'no entry point derives the root inline from $HOME any more' {
        # CODE lines only. The comments explaining this change deliberately quote the
        # old "$HOME/InventoryReports" form, and matching those would make the guard
        # fail on its own documentation.
        foreach ($Pair in @(
                @{ Name = 'ResourceInventory.ps1'; Src = $script:InvSrc },
                @{ Name = 'Run-AllSubscriptions.ps1'; Src = $script:WrapSrc },
                @{ Name = 'Run-AllSubscriptions.Stream.ps1'; Src = $script:StreamSrc }
            ))
        {
            $CodeLines = @($Pair.Src -split "`n" | Where-Object { $_ -notmatch '^\s*#' })
            $Offenders = @($CodeLines | Where-Object { $_ -match '\$HOME/InventoryReports' -or $_ -match 'C:\\InventoryReports' })
            $Offenders -join ' | ' | Should -BeNullOrEmpty -Because "$($Pair.Name) must resolve the root via Get-RdaInventoryRoot, not inline"
        }
    }

    It 'both entry points resolve the root through the shared function' {
        $script:InvSrc | Should -Match 'Get-RdaInventoryRoot'
        $script:WrapSrc | Should -Match 'Get-RdaInventoryRoot'
    }

    # Child processes must not re-probe and pick differently from their parent.
    It 'both entry points pin the resolved root for child processes' {
        $script:InvSrc | Should -Match 'Set-RdaInventoryRootForChildren'
        $script:WrapSrc | Should -Match 'Set-RdaInventoryRootForChildren'
    }

    # THE regression this file exists for. A bare `throw` at script scope is
    # discarded under $ErrorActionPreference = 'SilentlyContinue', so the pre-flight
    # gates announced "Pre-flight checks passed." and the run continued with exit 0.
    # Both remaining hard-fails must be `exit`, matching the -Service gate beside
    # them and the wrapper's Exit-Wrapper copy.
    It 'the inner pre-flight hard-fails with exit, never a bare throw' {
        # Use the AST, not a substring regex: the invariant is that every throw in the
        # pre-flight function sits inside a try whose catch terminates the run (a throw escaping to script scope is swallowed by SilentlyContinue). String matching failed on anchor collisions and nesting blindness.
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$null)

        $PreFlight = $Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'InvokePreFlightChecks'
            }, $true) | Select-Object -First 1

        if (-not $PreFlight)
        {
            # Not a function - locate the block by its banner comment and parse the
            # enclosing scriptblock instead, so this test cannot silently pass if the
            # code is restructured.
            $Start = $script:InvSrc.IndexOf('# === Pre-flight checks ===')
            $Start | Should -BeGreaterThan 0 -Because 'the pre-flight block must be locatable'
            $End = $script:InvSrc.LastIndexOf('Write-Host "Pre-flight checks passed."')
            $End | Should -BeGreaterThan $Start -Because 'the real completion line, not a comment mentioning it'
            $PreFlight = [System.Management.Automation.Language.Parser]::ParseInput(
                $script:InvSrc.Substring($Start, $End - $Start), [ref]$null, [ref]$null)
        }

        $Throws = @($PreFlight.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst]
                }, $true))

        # Every throw must sit inside a try whose catch block terminates the run.
        $Unprotected = @()
        foreach ($T in $Throws)
        {
            $Node = $T.Parent
            $Protected = $false
            while ($null -ne $Node)
            {
                if ($Node -is [System.Management.Automation.Language.TryStatementAst])
                {
                    foreach ($Catch in $Node.CatchClauses)
                    {
                        if ($Catch.Extent.Text -match '(^|\s)exit\s') { $Protected = $true; break }
                    }
                    if ($Protected) { break }
                }
                $Node = $Node.Parent
            }
            if (-not $Protected) { $Unprotected += ('L{0}: {1}' -f $T.Extent.StartLineNumber, $T.Extent.Text.Trim()) }
        }

        $Unprotected -join ' | ' | Should -BeNullOrEmpty -Because 'a throw that escapes to script scope is swallowed by SilentlyContinue and the gate becomes a no-op'
    }

    It 'the block boundary actually spans both gates, so the guard above is not vacuous' {
        # Guards the guard. If the anchors ever drift so that the examined region stops
        # before the disk floor or the write probe, the assertion above would pass by
        # omission - which is exactly how it passed before.
        $Start = $script:InvSrc.IndexOf('# === Pre-flight checks ===')
        $End = $script:InvSrc.LastIndexOf('Write-Host "Pre-flight checks passed."')
        $Block = $script:InvSrc.Substring($Start, $End - $Start)

        $Block | Should -Match '\$FreeMB' -Because 'the examined region must include the disk-space floor'
        $Block | Should -Match 'write-probe' -Because 'the examined region must include the write probe'
        $Block | Should -Match 'Write probe content mismatch' -Because 'the region must include the probe throw the AST check classifies'
    }

    It 'the disk-space floor and the write probe both stop the run' {
        $Start = $script:InvSrc.IndexOf('# === Pre-flight checks ===')
        $Block = $script:InvSrc.Substring($Start)

        # Disk floor: the comparison and a non-zero exit near it.
        $Block | Should -Match '(?s)\$FreeMB\s*-lt\s*100[\s\S]{0,600}?exit 1'
        # Write probe: its failure path must exit too.
        $Block | Should -Match '(?s)cannot write to[\s\S]{0,600}?exit 1'
    }

    # The report folder creation used to inherit SilentlyContinue with no catch, so
    # a failure produced a run with no output and no stated cause.
    It 'report-folder creation reports failure instead of continuing silently' {
        $script:InvSrc | Should -Match '(?s)New-Item -Type Directory -Force -Path \$DefaultPath -ErrorAction Stop[\s\S]{0,400}?catch'
        $script:InvSrc | Should -Match 'Could not create the report folder'
    }
}
