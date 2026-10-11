# Requires -Modules Pester
# Guard: product code must address file-system paths LITERALLY.
# -Path / -FilePath (and positional paths) are wildcard patterns on every file cmdlet, so an operator
# folder or report name containing '[' or ']' either fails hard (Out-File, Compress-Archive destination:
# 'Unable to find the specified file') or silently resolves to a SIBLING (wrong file zipped, deleted, or
# read). Use -LiteralPath everywhere; globs belong on -Filter; Compress-Archive -DestinationPath has no
# literal form and must be wrapped in [WildcardPattern]::Escape().

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    # Every file cmdlet the product calls whose -Path / -FilePath (or positional path) is a wildcard pattern.
    $script:Guarded = @('Get-ChildItem', 'Test-Path', 'Remove-Item', 'Compress-Archive', 'Expand-Archive',
        'Out-File', 'Set-Content', 'Add-Content', 'Get-Content', 'Clear-Content', 'Export-Csv', 'Import-Csv',
        'Copy-Item', 'Move-Item', 'Rename-Item', 'Get-Item', 'Resolve-Path', 'Start-Transcript', 'Select-String',
        'Export-Clixml', 'Import-Clixml')

    function Get-NonLiteralSites([string]$File)
    {
        $Tokens = $null; $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$Tokens, [ref]$Errors)
        if ($Errors.Count) { throw "parse error in $File : $($Errors[0].Message)" }
        $Sites = @()
        foreach ($Cmd in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))
        {
            if ($script:Guarded -notcontains $Cmd.GetCommandName()) { continue }
            $Params = @($Cmd.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object ParameterName)
            if ($Params -contains 'LiteralPath') { continue }
            $Splatted = @($Cmd.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted })
            if ($Splatted.Count -gt 0) { continue }   # splats are checked by name below
            $Positional = $Cmd.CommandElements.Count -gt 1 -and $Cmd.CommandElements[1] -isnot [System.Management.Automation.Language.CommandParameterAst]
            if ($Params -contains 'Path' -or $Params -contains 'FilePath' -or $Positional)
            {
                $Sites += ('{0}:{1} {2}' -f $File.Replace($script:Repo, '').TrimStart('/', '\'), $Cmd.Extent.StartLineNumber, $Cmd.Extent.Text.Split("`n")[0].Trim())
            }
        }
        return $Sites
    }

    $script:ProductFiles = @(Get-ChildItem -LiteralPath $script:Repo -Recurse -File -Include '*.ps1', '*.psm1' |
            Where-Object { $_.FullName -notmatch '[\\/](Tests|\.exploration|\.kiro|\.git|deploy)[\\/]' } |
            Select-Object -ExpandProperty FullName)
}

Describe 'Literal path discipline (bracket-safe file access)' {
    It 'finds product files to check' {
        $script:ProductFiles.Count | Should -BeGreaterThan 20
    }

    It 'never addresses a file with -Path / -FilePath / a positional path on a wildcard-capable cmdlet' {
        $Offenders = @(foreach ($F in $script:ProductFiles) { Get-NonLiteralSites $F })
        $Offenders | Should -BeNullOrEmpty -Because ("each of these treats '[' and ']' as wildcards; use -LiteralPath (and -Filter for globs):`n" + ($Offenders -join "`n"))
    }

    It 'escapes every Compress-Archive -DestinationPath (the module globs it even under -LiteralPath)' {
        $Offenders = @(foreach ($F in $script:ProductFiles)
            {
                $Tokens = $null; $Errors = $null
                $Ast = [System.Management.Automation.Language.Parser]::ParseFile($F, [ref]$Tokens, [ref]$Errors)
                foreach ($Cmd in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq 'Compress-Archive' }, $true))
                {
                    $Els = $Cmd.CommandElements
                    for ($i = 0; $i -lt $Els.Count - 1; $i++)
                    {
                        if ($Els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $Els[$i].ParameterName -eq 'DestinationPath' -and $Els[$i + 1].Extent.Text -notmatch 'WildcardPattern\]::Escape')
                        {
                            '{0}:{1}' -f $F.Replace($script:Repo, '').TrimStart('/', '\'), $Cmd.Extent.StartLineNumber
                        }
                    }
                }
                foreach ($H in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.HashtableAst] }, $true))
                {
                    foreach ($Kv in $H.KeyValuePairs)
                    {
                        if ($Kv.Item1.Extent.Text -eq 'DestinationPath' -and $Kv.Item2.Extent.Text -notmatch 'WildcardPattern\]::Escape')
                        {
                            '{0}:{1} (splat)' -f $F.Replace($script:Repo, '').TrimStart('/', '\'), $Kv.Item1.Extent.StartLineNumber
                        }
                    }
                }
            })
        $Offenders | Should -BeNullOrEmpty -Because ("Compress-Archive resolves -DestinationPath as a wildcard:`n" + ($Offenders -join "`n"))
    }

    It 'builds the per-subscription report zip with LiteralPath in every Compress-Archive splat' {
        $Src = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'ResourceInventory.ps1')
        $Src | Should -Not -Match '(?m)^\s*Path\s*=\s*@\(\$Global:HtmlFile'
        ([regex]::Matches($Src, '(?m)^\s*LiteralPath\s*=\s*@\(\$Global:HtmlFile')).Count | Should -Be 2
    }

    It 'finds the metrics shards for the no-report message, even under a bracketed report folder' {
        # Runs the FinalizeOutputs statements as written, so a parameter-set error or a wildcard path
        # shows up here instead of as a 'Metrics JSON' label silently left off the message.
        $Tokens = $null; $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo 'ResourceInventory.ps1'), [ref]$Tokens, [ref]$Errors)
        $Errors | Should -BeNullOrEmpty
        $Check = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -match 'Get-ChildItem .*\$MetricsShardFilter' }, $true))
        $Check.Count | Should -Be 1
        # Only the assignment that sits before the check in the same block, in source order.
        $Setup = @($Check[0].Parent.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$MetricsShardFilter' -and $_.Extent.EndOffset -le $Check[0].Extent.StartOffset })
        $Setup.Count | Should -Be 1
        $Probe = [scriptblock]::Create($Setup[0].Extent.Text + "`n" + $Check[0].Clauses[0].Item1.Extent.Text)
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $Base = Join-Path $TmpBase ('MetricsShardProbe_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $GlobalNames = @('MetricsJsonFile', 'DefaultPath', 'ReportName', 'CurrentDateTime')
        # Values, not the PSVariable objects: assigning a global below changes the object in place.
        $Saved = @{}
        foreach ($Name in $GlobalNames)
        {
            $Existing = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
            if ($Existing) { $Saved[$Name] = $Existing.Value }
        }
        try
        {
            $Folder = [System.IO.Directory]::CreateDirectory((Join-Path $Base 'Report[1]')).FullName
            $Global:DefaultPath = $Folder + [IO.Path]::DirectorySeparatorChar
            $Global:ReportName = 'R[1]'
            $Global:CurrentDateTime = '2026'
            $Global:MetricsJsonFile = $Global:DefaultPath + 'Metrics_R[1]_2026.json'
            [System.IO.File]::WriteAllText((Join-Path $Folder 'Metrics_R[1]_2026__1.json'), '{}')
            & $Probe | Should -BeExactly $true
            # Negative control: no shard of this report, only decoys a wildcard or a lost prefix would match.
            Remove-Item -LiteralPath (Join-Path $Folder 'Metrics_R[1]_2026__1.json') -Force
            foreach ($Decoy in @('Metrics_R1_2026__1.json', 'Metrics_Other_2026__1.json', 'Metrics_R[1]_1999__1.json', 'Inventory_R[1]_2026.json'))
            {
                [System.IO.File]::WriteAllText((Join-Path $Folder $Decoy), '{}')
            }
            & $Probe | Should -BeExactly $false
            # A run whose output paths were never set answers no, instead of failing on a null folder.
            $Global:DefaultPath = $null
            & $Probe | Should -BeExactly $false
        }
        finally
        {
            foreach ($Name in $GlobalNames)
            {
                if ($Saved.ContainsKey($Name)) { Set-Variable -Name $Name -Scope Global -Value $Saved[$Name] }
                else { Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue }
            }
            if (Test-Path -LiteralPath $Base) { Remove-Item -LiteralPath $Base -Recurse -Force }
        }
    }
}

Describe 'Why the guard exists: Compress-Archive -Path silently archives a sibling' {
    BeforeAll {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $script:Dir = Join-Path $TmpBase ('LiteralPathDemo_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dir 'ResourcesReport_[1].zip') -Value 'WANTED'
        Set-Content -LiteralPath (Join-Path $script:Dir 'ResourcesReport_1.zip') -Value 'DECOY'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        function Get-SingleEntryName([string]$Zip)
        {
            $A = [System.IO.Compression.ZipFile]::OpenRead($Zip); try { return @($A.Entries)[0].Name } finally { $A.Dispose() }
        }
    }
    AfterAll { if ($script:Dir -and (Test-Path -LiteralPath $script:Dir)) { Remove-Item -LiteralPath $script:Dir -Recurse -Force } }

    It '-Path picks the decoy that matches the bracket pattern (the bug)' {
        $Out = Join-Path $script:Dir 'out-path.zip'
        Compress-Archive -Path (Join-Path $script:Dir 'ResourcesReport_[1].zip') -DestinationPath $Out -Force
        Get-SingleEntryName $Out | Should -Be 'ResourcesReport_1.zip'
    }

    It '-LiteralPath archives the file that was named (the fix)' {
        $Out = Join-Path $script:Dir 'out-literal.zip'
        Compress-Archive -LiteralPath (Join-Path $script:Dir 'ResourcesReport_[1].zip') -DestinationPath $Out -Force
        Get-SingleEntryName $Out | Should -Be 'ResourcesReport_[1].zip'
    }
}
