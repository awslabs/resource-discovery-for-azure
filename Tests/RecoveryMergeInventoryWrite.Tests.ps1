# Recovery merge inventory write tests
# =============================================================================
# Offline tests for how Merge-RecoveryData (Functions/RecoveryMerge.Functions.ps1)
# writes the merged Inventory_*.json.
#
# WHY THIS TEST EXISTS
# --------------------
# Serialising the whole merged inventory as one ConvertTo-Json string can run
# out of memory on a large estate, and the old ConvertTo-Json | Out-File
# pipeline opened the output file before serialising, so a failure left a
# 0-byte inventory behind. The merged inventory is now written with
# Write-InventoryJson (one collector at a time, temporary file moved into place
# only when complete), and the bytes are the same as the old pipeline wrote.
#
# HOW
# ---
# One case runs in a fresh pwsh that dot-sources ONLY RecoveryMerge.Functions.ps1,
# as docs/recovery-and-diagnostics.md tells users to, so it proves the file
# loads what it needs on its own. The other cases dot-source the same file
# in-process and mock ConvertTo-Json as a pass-through to watch the calls.
# No live Azure.
#
# Run with: Invoke-Pester ./Tests/RecoveryMergeInventoryWrite.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:FnFile = Join-Path $script:RepoRoot 'Functions/RecoveryMerge.Functions.ps1'
    if (-not (Test-Path -LiteralPath $script:FnFile -PathType Leaf)) { throw "RecoveryMerge.Functions.ps1 not found at $script:FnFile" }

    $script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('RecoveryMergeWriteTest_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null

    $script:DocsGuid = '12345678-1234-1234-1234-123456789012'
    $script:GapBase = 'GapReport_20260101_000000'
    $script:RecBase = 'RecReport_20260102_000000'

    # The real cmdlet, for pass-through mocks and reference output while a mock is active.
    $script:RealConvertToJson = Get-Command -Name 'ConvertTo-Json' -CommandType Cmdlet
    $script:PassThroughConvertToJson = {
        & $script:RealConvertToJson -InputObject $InputObject -Depth $Depth -Compress:$Compress
    }
    # Pass-through that fails on any value holding the marker record, the way a
    # large collector can fail with OutOfMemoryException part-way through.
    $script:FailingConvertToJson = {
        $Text = & $script:RealConvertToJson -InputObject $InputObject -Depth $Depth -Compress:$Compress
        if ($Text -match 'fail-marker') { throw [System.OutOfMemoryException]::new('simulated out of memory') }
        $Text
    }

    function New-Record([string]$Name)
    {
        [ordered]@{
            Name          = $Name
            Subscription  = 'prod_sub'
            Location      = 'eastus'
            ResourceGroup = 'rg-app'
            ID            = ('/subscriptions/{0}/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/{1}' -f $script:DocsGuid, $Name)
        }
    }

    # Gap bundle: nested objects, unicode, an empty list, a one-element list, a
    # date string, numbers, null and a Version marker. Recovery bundle: one
    # collector that the gap lacks, plus one that replaces a gap collector.
    function New-WriteCase
    {
        param([string]$RecoveryVmName = 'vm-rec-01')

        $Id = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $Case = [pscustomobject]@{
            Gap      = Join-Path $script:TmpRoot ("gap_$Id")
            Recovery = Join-Path $script:TmpRoot ("rec_$Id")
            Output   = Join-Path $script:TmpRoot ("out_$Id")
        }
        New-Item -ItemType Directory -Path $Case.Gap, $Case.Recovery -Force | Out-Null

        $Vm = New-Record 'vm-gap-01'
        $Vm['Tags'] = @([ordered]@{ Name = 'owner'; Value = 'Zürich team' }, [ordered]@{ Name = 'cost'; Value = '東京-42 ✓' })
        $Vm['Disks'] = @([ordered]@{ Lun = 0; SizeGB = 128; Caching = 'ReadOnly' }, [ordered]@{ Lun = 1; SizeGB = 1024; Caching = $null })
        $Vm['Network'] = [ordered]@{ Nics = @([ordered]@{ Ip = '203.0.113.4'; Rules = @() }); Notes = "line1`nline2`t""quoted"" back\slash <tag> & ünïcödé" }
        $Vm['Created'] = '2026-01-02T03:04:05Z'
        $Vm['Score'] = 0.75
        $Gap = [ordered]@{
            VirtualMachines = @($Vm)
            Disks           = @()
            AppServices     = @(New-Record 'app-gap-old')
            KeyVaults       = @(New-Record 'kv-ä-01'; New-Record 'kv-02')
            Version         = '1.2.3'
        }
        $Recovery = [ordered]@{
            AppServices      = @(New-Record 'app-rec-01'; New-Record 'app-rec-02')
            StorageAccounts  = @([ordered]@{ Name = 'stäccount01'; Network = [ordered]@{ DefaultAction = 'Deny'; Rules = @() } })
            RecoveredVMs     = @(New-Record $RecoveryVmName)
            Version          = '1.2.3'
        }
        ($Gap | & $script:RealConvertToJson -Depth 100) | Out-File -FilePath (Join-Path $Case.Gap ('Inventory_{0}.json' -f $script:GapBase)) -Encoding utf8
        ($Recovery | & $script:RealConvertToJson -Depth 100) | Out-File -FilePath (Join-Path $Case.Recovery ('Inventory_{0}.json' -f $script:RecBase)) -Encoding utf8
        return $Case
    }

    # The bytes the old '$GapInventory | ConvertTo-Json -Depth 100 -Compress | Out-File'
    # line wrote for this case: the same load and splice Merge-RecoveryData does.
    function Get-ReferenceBytes($Case)
    {
        $GapInventory = Get-Content -Path (Join-Path $Case.Gap ('Inventory_{0}.json' -f $script:GapBase)) -Raw | ConvertFrom-Json
        $RecoveryInventory = Get-Content -Path (Join-Path $Case.Recovery ('Inventory_{0}.json' -f $script:RecBase)) -Raw | ConvertFrom-Json
        foreach ($Key in @($RecoveryInventory.PSObject.Properties.Name | Where-Object { $_ -ne 'Version' }))
        {
            $GapInventory | Add-Member -NotePropertyName $Key -NotePropertyValue $RecoveryInventory.$Key -Force
        }
        $ReferenceFile = Join-Path $script:TmpRoot ('reference_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        $GapInventory | & $script:RealConvertToJson -Depth 100 -Compress | Out-File -FilePath $ReferenceFile
        return [System.IO.File]::ReadAllBytes($ReferenceFile)
    }

    function Get-OutputInventoryPath($Case)
    {
        return (Join-Path $Case.Output ('Inventory_{0}.json' -f $script:GapBase))
    }
}

AfterAll {
    if ($script:TmpRoot -and (Test-Path -LiteralPath $script:TmpRoot))
    {
        Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Merge-RecoveryData run from a fresh pwsh that loads only RecoveryMerge.Functions.ps1' {

    It 'has Write-InventoryJson in scope and writes the same bytes as the old pipeline' {
        $Case = New-WriteCase
        $Pwsh = (Get-Process -Id $PID).Path
        $Q = { param($s) "'" + ($s -replace "'", "''") + "'" }
        $ChildScript = @(
            '$ErrorActionPreference = ''Stop'''
            ('. {0}' -f (& $Q $script:FnFile))
            '$HasWriter = [bool](Get-Command -Name ''Write-InventoryJson'' -CommandType Function -ErrorAction SilentlyContinue)'
            'Write-Output (''HAS_WRITER='' + $HasWriter)'
            ('$Result = Merge-RecoveryData -GapBundlePath {0} -RecoveryBundlePath {1} -OutputPath {2} 3>$null' -f (& $Q $Case.Gap), (& $Q $Case.Recovery), (& $Q $Case.Output))
            'Write-Output (''OUTPUT='' + $Result.OutputInventory)'
        ) -join [Environment]::NewLine
        $ChildFile = Join-Path $script:TmpRoot ('child_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        Set-Content -LiteralPath $ChildFile -Value $ChildScript -Encoding utf8

        $ChildOutput = @(& $Pwsh -NoProfile -NonInteractive -File $ChildFile 2>&1 | ForEach-Object { [string]$_ })
        $LASTEXITCODE | Should -Be 0 -Because ($ChildOutput -join [Environment]::NewLine)
        $ChildOutput | Should -Contain 'HAS_WRITER=True' -Because 'RecoveryMerge.Functions.ps1 must load Write-InventoryJson itself when dot-sourced alone'

        $OutPath = Get-OutputInventoryPath $Case
        $ChildOutput | Should -Contain ('OUTPUT=' + $OutPath)
        $New = [System.IO.File]::ReadAllBytes($OutPath)
        $New.Length | Should -BeGreaterThan 0
        [Convert]::ToBase64String($New) | Should -BeExactly ([Convert]::ToBase64String((Get-ReferenceBytes $Case)))
        @(Get-ChildItem -LiteralPath $Case.Output -Filter '*.tmp' -Force).Count | Should -Be 0
    }

    It 'leaves the caller''s variables and its own Write-Log and Write-RdaProgress as they were' {
        # docs/recovery-and-diagnostics.md has operators dot-source the file at their own
        # prompt, so loading it must change nothing there but add its own functions.
        $Pwsh = (Get-Process -Id $PID).Path
        $Q = { param($s) "'" + ($s -replace "'", "''") + "'" }
        $ChildScript = @(
            '$ErrorActionPreference = ''Stop'''
            'function Global:Write-Log { ''sentinel-log'' }'
            'function Write-RdaProgress { ''sentinel-progress'' }'
            '$RecoveryMergeCommonFunctions = ''sentinel-var'''
            '$Before = @(Get-Variable | ForEach-Object { $_.Name })'
            ('. {0}' -f (& $Q $script:FnFile))
            '$After = @(Get-Variable | ForEach-Object { $_.Name })'
            'Write-Output (''LOG='' + (Get-Command -Name ''Write-Log'' -CommandType Function).ScriptBlock.ToString().Trim())'
            'Write-Output (''PROGRESS='' + (Get-Command -Name ''Write-RdaProgress'' -CommandType Function).ScriptBlock.ToString().Trim())'
            'Write-Output (''VAR='' + $RecoveryMergeCommonFunctions)'
            'Write-Output (''NEWVARS='' + ((@($After | Where-Object { $Before -notcontains $_ -and $_ -ne ''Before'' }) | Sort-Object) -join '',''))'
            'Write-Output (''HAS_WRITER='' + [bool](Get-Command -Name ''Write-InventoryJson'' -CommandType Function -ErrorAction SilentlyContinue))'
            'Write-Output (''HAS_MERGE='' + [bool](Get-Command -Name ''Merge-RecoveryData'' -CommandType Function -ErrorAction SilentlyContinue))'
        ) -join [Environment]::NewLine
        $ChildFile = Join-Path $script:TmpRoot ('child_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        Set-Content -LiteralPath $ChildFile -Value $ChildScript -Encoding utf8

        $ChildOutput = @(& $Pwsh -NoProfile -NonInteractive -File $ChildFile 2>&1 | ForEach-Object { [string]$_ })
        $LASTEXITCODE | Should -Be 0 -Because ($ChildOutput -join [Environment]::NewLine)
        # One comparison, so a failure shows every line that differs.
        @($ChildOutput | Where-Object { $_ -match '^(LOG|PROGRESS|VAR|NEWVARS|HAS_WRITER|HAS_MERGE)=' }) | Should -Be @(
            'LOG=''sentinel-log'''
            'PROGRESS=''sentinel-progress'''
            'VAR=sentinel-var'
            'NEWVARS='
            'HAS_WRITER=True'
            'HAS_MERGE=True'
        ) -Because 'loading the file must keep the caller''s Write-Log, Write-RdaProgress and variables, add no variable, and define Write-InventoryJson and Merge-RecoveryData'
    }

    # Pester runs each test inside a try, and a throw inside a try always stops. So the
    # caller here is a child pwsh with no try at all, as an operator's own script would be.
    It 'stops the caller when InventoryJson.Functions.ps1 is missing, under ErrorActionPreference <Preference>' -ForEach @(
        @{ Preference = 'SilentlyContinue' }
        @{ Preference = 'Ignore' }
        @{ Preference = 'Continue' }
    ) {
        # A Functions folder holding only RecoveryMerge.Functions.ps1.
        $LoneDir = Join-Path $script:TmpRoot ('lone_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $LoneDir -Force | Out-Null
        $LoneFile = Join-Path $LoneDir 'RecoveryMerge.Functions.ps1'
        Copy-Item -LiteralPath $script:FnFile -Destination $LoneFile

        $Pwsh = (Get-Process -Id $PID).Path
        $Q = { param($s) "'" + ($s -replace "'", "''") + "'" }
        $ChildScript = @(
            ('$ErrorActionPreference = {0}' -f (& $Q $Preference))
            ('. {0}' -f (& $Q $LoneFile))
            'Write-Output ''AFTER_LOAD'''
            'Write-Output (''HAS_MERGE='' + [bool](Get-Command -Name ''Merge-RecoveryData'' -CommandType Function -ErrorAction SilentlyContinue))'
        ) -join [Environment]::NewLine
        $ChildFile = Join-Path $script:TmpRoot ('child_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        Set-Content -LiteralPath $ChildFile -Value $ChildScript -Encoding utf8

        $ChildOutput = @(& $Pwsh -NoProfile -NonInteractive -File $ChildFile 2>&1 | ForEach-Object { [string]$_ })
        $Because = $ChildOutput -join [Environment]::NewLine
        $ChildOutput | Should -Not -Contain 'AFTER_LOAD' -Because ('the load must stop the caller, not let it go on. Output: ' + $Because)
        @($ChildOutput | Where-Object { $_ -like 'HAS_MERGE=*' }) | Should -BeNullOrEmpty -Because $Because
        $Because | Should -BeLike '*required file not found*InventoryJson.Functions.ps1*Keep the Functions folder together*'
        $LASTEXITCODE | Should -Not -Be 0 -Because $Because
    }
}

Describe 'Merge-RecoveryData inventory write' {

    BeforeAll {
        . $script:FnFile
    }

    It 'writes the merged inventory one collector at a time with the same bytes as before' {
        $Case = New-WriteCase
        $Reference = Get-ReferenceBytes $Case

        Mock -CommandName ConvertTo-Json -MockWith $script:PassThroughConvertToJson
        $Result = Merge-RecoveryData -GapBundlePath $Case.Gap -RecoveryBundlePath $Case.Recovery -OutputPath $Case.Output 3>$null

        # The merged root is the only object that holds both a gap and a recovery collector.
        Should -Invoke -CommandName ConvertTo-Json -Times 0 -Exactly -ParameterFilter {
            $null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties['VirtualMachines'] -and $null -ne $InputObject.PSObject.Properties['StorageAccounts']
        } -Because 'the whole merged inventory must never be one in-memory string'
        $Result.OutputInventory | Should -Be (Get-OutputInventoryPath $Case)
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Result.OutputInventory)) | Should -BeExactly ([Convert]::ToBase64String($Reference))

        $Text = [System.IO.File]::ReadAllText($Result.OutputInventory)
        $Text | Should -Match '"Disks":\[\],'
        $Text | Should -Match '"StorageAccounts":\[\{'
        $Text | Should -Match 'Zürich team'
        $Text.EndsWith('}' + [Environment]::NewLine) | Should -BeTrue
    }

    It 'leaves no inventory file (not even 0 bytes) and no temporary file when the write fails' {
        $Case = New-WriteCase -RecoveryVmName 'fail-marker'

        Mock -CommandName ConvertTo-Json -MockWith $script:FailingConvertToJson
        { Merge-RecoveryData -GapBundlePath $Case.Gap -RecoveryBundlePath $Case.Recovery -OutputPath $Case.Output 3>$null } | Should -Throw '*simulated out of memory*'

        Test-Path -LiteralPath (Get-OutputInventoryPath $Case) | Should -BeFalse -Because 'a failed write must not leave a cut-off or empty inventory'
        @(Get-ChildItem -LiteralPath $Case.Output -Force | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty -Because 'the merge stops at the inventory write and leaves nothing behind'
    }

    It 'leaves an existing inventory in the output folder byte-for-byte unchanged when the write fails' {
        $Case = New-WriteCase -RecoveryVmName 'fail-marker'
        New-Item -ItemType Directory -Path $Case.Output -Force | Out-Null
        $Existing = Get-OutputInventoryPath $Case
        # An inventory from an earlier good run, longer than a cut-off write would be.
        [System.IO.File]::WriteAllText($Existing, ('{"VirtualMachines":[' + ((1..200 | ForEach-Object { '{"Name":"vm-old-' + $_ + '"}' }) -join ',') + '],"Version":"1.2.3"}' + [Environment]::NewLine))
        $Before = [System.IO.File]::ReadAllBytes($Existing)

        Mock -CommandName ConvertTo-Json -MockWith $script:FailingConvertToJson
        { Merge-RecoveryData -GapBundlePath $Case.Gap -RecoveryBundlePath $Case.Recovery -OutputPath $Case.Output 3>$null } | Should -Throw '*simulated out of memory*'

        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Existing)) | Should -BeExactly ([Convert]::ToBase64String($Before)) -Because 'a failed write must not truncate or replace the inventory already there'
        @(Get-ChildItem -LiteralPath $Case.Output -Force | ForEach-Object { $_.Name }) | Should -Be @(Split-Path -Leaf $Existing) -Because 'no temporary file is left next to it'
    }

    # Regression check, not a proof of the fix: this also passes with the old
    # ConvertTo-Json | Out-File line, which overwrote its own 0-byte file on the
    # next run. It guards that nothing the new write path leaves after a failure
    # stops the next run. The fix itself is proven by the two tests above.
    It 'regression check: the next run after a failed write succeeds, with nothing kept from the failed one' {
        $Case = New-WriteCase -RecoveryVmName 'fail-marker'

        Mock -CommandName ConvertTo-Json -MockWith $script:FailingConvertToJson
        { Merge-RecoveryData -GapBundlePath $Case.Gap -RecoveryBundlePath $Case.Recovery -OutputPath $Case.Output 3>$null } | Should -Throw

        Mock -CommandName ConvertTo-Json -MockWith $script:PassThroughConvertToJson
        $Result = Merge-RecoveryData -GapBundlePath $Case.Gap -RecoveryBundlePath $Case.Recovery -OutputPath $Case.Output 3>$null

        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Result.OutputInventory)) | Should -BeExactly ([Convert]::ToBase64String((Get-ReferenceBytes $Case)))
        Test-Path -LiteralPath $Result.OutputZip | Should -BeTrue
        @(Get-ChildItem -LiteralPath $Case.Output -Filter '*.tmp' -Force).Count | Should -Be 0
    }
}
