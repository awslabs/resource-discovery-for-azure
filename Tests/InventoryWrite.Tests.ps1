# Inventory JSON write tests
# =============================================================================
# Offline tests for how ResourceInventory.ps1 writes Inventory_*.json and how
# it frees the collector data afterwards while keeping the resource count the
# wrappers read.
#
# WHY THIS TEST EXISTS
# --------------------
# Serialising the whole inventory as one ConvertTo-Json string can run out of
# memory on a large estate. The inventory is now written one collector at a
# time (Write-InventoryJson), and the file is byte-for-byte what the previous
# ConvertTo-Json | Out-File pipeline wrote. The collector output and the raw
# discovery rows are released once the inventory is written, so the report
# step has that memory; the per-run resource count the wrappers read is kept
# in $Global:ResourceCount.
#
# HOW
# ---
# Write-InventoryJson is dot-sourced from Functions/ResourceInventory.Functions.ps1
# and tested directly. ResourceInventory.ps1 runs login and collection when
# invoked, so its parts are lifted out with the PowerShell parser: the functions
# it defines, the top-level statements of RunInventorySetup and
# ExecuteInventoryProcessing (their nested Azure-facing functions are replaced
# by stubs), and the top-level statements of the script from the setup block
# ($Global:Runtime = Measure-Command { ... }) onwards. The run-level cases run
# those in a child pwsh process, in-process as the wrappers call the script,
# with Extension/Summary.ps1 and Write-RdaShareableDiagnosticsLog stubbed. The
# wrapper cases lift the try block around each in-process call to
# ResourceInventory.ps1 out of the wrappers and run it against a stub inventory
# script. No live Azure, no output zip.
#
# Run with: Invoke-Pester ./Tests/InventoryWrite.Tests.ps1 -Output Detailed
# =============================================================================

BeforeDiscovery {
    # The behaviour test for the Azure session read needs the real Az.Accounts module.
    $script:HasAzAccounts = [bool](Get-Module -ListAvailable -Name Az.Accounts)
}

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:InventoryScript = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    $script:CommonFunctions = Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1'
    $script:InventoryFunctions = Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1'
    foreach ($Required in @($script:InventoryScript, $script:CommonFunctions, $script:InventoryFunctions))
    {
        if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Required file not found: $Required" }
    }

    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InventoryScript, [ref]$Tokens, [ref]$ParseErrors)
    if (@($ParseErrors).Count -gt 0) { throw ("ResourceInventory.ps1 does not parse: {0}" -f $ParseErrors[0].Message) }

    function Get-FunctionText([string]$Name)
    {
        $Fn = $Ast.FindAll({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name
            }, $true) | Select-Object -First 1
        if ($null -eq $Fn) { throw "$Name was not found in ResourceInventory.ps1. Has it been renamed or removed?" }
        return $Fn.Extent.Text
    }
    $script:ProcessResourceResultText = Get-FunctionText 'ProcessResourceResult'
    $script:FinalizeOutputsText = Get-FunctionText 'FinalizeOutputs'
    $script:VariablesText = Get-FunctionText 'Variables'
    $script:InitializeInventoryProcessingText = Get-FunctionText 'InitializeInventoryProcessing'

    # A function's own top-level statements without the functions nested in it, so a
    # test can supply those (the Azure-facing steps) while the real call sequence runs.
    function Get-FunctionFlowText([string]$Name)
    {
        $Fn = $Ast.FindAll({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name
            }, $false) | Select-Object -First 1
        if ($null -eq $Fn) { throw "$Name was not found in ResourceInventory.ps1. Has it been renamed or removed?" }
        $Statements = @($Fn.Body.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] })
        return ('function {0}{1}{{{1}{2}{1}}}' -f $Name, [Environment]::NewLine, (($Statements | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine))
    }
    $script:RunInventorySetupFlowText = Get-FunctionFlowText 'RunInventorySetup'
    $script:ExecuteInventoryProcessingFlowText = Get-FunctionFlowText 'ExecuteInventoryProcessing'
    if ($script:RunInventorySetupFlowText -notmatch 'ResourceInventoryAvd') { throw 'RunInventorySetup no longer calls ResourceInventoryAvd; the run harness would not exercise discovery.' }
    if ($script:ExecuteInventoryProcessingFlowText -notmatch 'ProcessResourceResult') { throw 'ExecuteInventoryProcessing no longer calls ProcessResourceResult; the run harness would not exercise the write.' }

    $Top = @($Ast.EndBlock.Statements)
    $SetupIndex = -1
    for ($i = 0; $i -lt $Top.Count; $i++)
    {
        if ($Top[$i].Extent.Text -like '$Global:Runtime = Measure-Command*') { $SetupIndex = $i; break }
    }
    if ($SetupIndex -lt 0 -or $SetupIndex -ge ($Top.Count - 1)) { throw 'The $Global:Runtime setup statement was not found in ResourceInventory.ps1, so the script tail cannot be located.' }
    $script:RunText = (@($Top[$SetupIndex..($Top.Count - 1)] | ForEach-Object { $_.Extent.Text })) -join [Environment]::NewLine
    if ($script:RunText -notmatch 'ExecuteInventoryProcessing') { throw 'The script tail does not call ExecuteInventoryProcessing; the harness would not exercise the processing step.' }

    # The try block around each in-process call to ResourceInventory.ps1 in the wrappers.
    $script:WrapperCallSites = @{}
    foreach ($WrapperName in 'Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1')
    {
        $WrapperTokens = $null
        $WrapperErrors = $null
        $WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $WrapperName), [ref]$WrapperTokens, [ref]$WrapperErrors)
        if (@($WrapperErrors).Count -gt 0) { throw ("{0} does not parse: {1}" -f $WrapperName, $WrapperErrors[0].Message) }
        $Calls = @($WrapperAst.FindAll({
                    param($Node)
                    $Node -is [System.Management.Automation.Language.CommandAst] -and
                    $Node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
                    $Node.Extent.Text -match 'ResourceInventory\.ps1'
                }, $true) | Sort-Object { $_.Extent.StartOffset })
        $script:WrapperCallSites[$WrapperName] = @($Calls | ForEach-Object {
                $Node = $_.Parent
                while ($null -ne $Node -and $Node -isnot [System.Management.Automation.Language.TryStatementAst]) { $Node = $Node.Parent }
                if ($null -eq $Node) { throw "A call to ResourceInventory.ps1 in $WrapperName is not inside a try block." }
                $Node.Extent.Text
            })
    }
    if (@($script:WrapperCallSites['Run-AllSubscriptions.ps1']).Count -ne 2 -or @($script:WrapperCallSites['Run-AllSubscriptions.Stream.ps1']).Count -ne 1)
    {
        throw 'Expected two calls to ResourceInventory.ps1 in Run-AllSubscriptions.ps1 and one in Run-AllSubscriptions.Stream.ps1; update the wrapper tests below.'
    }

    $script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('InventoryWriteTest_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null

    $script:DocsGuid = '12345678-1234-1234-1234-123456789012'

    # Inventory shaped the way CreateResourceJobs and ProcessResourceResult build
    # it: a PSObject with one NoteProperty per collector, each value an array
    # (@($Result)), and Version added last unless -WithoutVersion.
    function New-InventoryFixture
    {
        param([switch]$WithoutVersion)

        $Inv = New-Object PSObject
        $Vms = @(
            [ordered]@{
                ID            = ('/subscriptions/{0}/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm-01' -f $script:DocsGuid)
                Name          = 'vm-01'
                Location      = 'westeurope'
                Size          = 'Standard_D2s_v5'
                Zones         = @('1')
                Tags          = @([pscustomobject]@{ Name = 'owner'; Value = 'Zürich team' }, [pscustomobject]@{ Name = 'cost'; Value = '東京-42' })
                Disks         = @([ordered]@{ Lun = 0; SizeGB = 128; Caching = 'ReadOnly' }, [ordered]@{ Lun = 1; SizeGB = 1024; Caching = $null })
                Running       = $true
                Score         = 0.75
                Notes         = "line1`nline2`ttab ""quoted"" back\slash <tag> & ünïcödé ✓"
            },
            [pscustomobject]@{
                ID       = ('/subscriptions/{0}/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm-02' -f $script:DocsGuid)
                Name     = 'vm-02'
                Location = 'eastus'
                Size     = $null
                Zones    = @()
                Tags     = @()
                Running  = $false
                Created  = [datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc)
            }
        )
        $Inv | Add-Member -MemberType NoteProperty -Name 'VirtualMachines' -Value NotSet
        $Inv.VirtualMachines = @($Vms)
        $Inv | Add-Member -MemberType NoteProperty -Name 'Disks' -Value NotSet
        $Inv.Disks = @()
        $Inv | Add-Member -MemberType NoteProperty -Name 'StorageAccounts' -Value NotSet
        $Inv.StorageAccounts = @([ordered]@{ Name = 'stäccount01'; Kind = 'StorageV2'; Network = [ordered]@{ DefaultAction = 'Deny'; Rules = @([ordered]@{ Ip = '203.0.113.0/24' }) } })
        $Inv | Add-Member -MemberType NoteProperty -Name 'KeyVaults' -Value NotSet
        $Inv.KeyVaults = @(1..3 | ForEach-Object { [ordered]@{ Name = ('kv-{0:d2}' -f $_); SoftDelete = ($_ % 2 -eq 0) } })
        # Nested past the old -depth 100 limit, so the truncation point must match too.
        $Deep = 'leaf'
        for ($i = 0; $i -lt 101; $i++) { $Deep = [ordered]@{ Level = $Deep } }
        $Inv | Add-Member -MemberType NoteProperty -Name 'Deep' -Value NotSet
        $Inv.Deep = @(, $Deep)
        if (-not $WithoutVersion)
        {
            $Inv | Add-Member -MemberType NoteProperty -Name 'Version' -Value NotSet
            $Inv.Version = '1.2.3'
        }
        return $Inv
    }

    # The real cmdlet, for pass-through mocks and for building reference output while a
    # mock is active. Pester also mocks the module-qualified name, so it is called through
    # its CmdletInfo.
    $script:RealConvertToJson = Get-Command -Name 'ConvertTo-Json' -CommandType Cmdlet
    # Body for a pass-through mock. $PSBoundParameters is empty inside a Pester mock body,
    # so the parameters the product code uses are passed on by name.
    $script:PassThroughConvertToJson = {
        & $script:RealConvertToJson -InputObject $InputObject -Depth $Depth -Compress:$Compress
    }

    # Extension/Summary.ps1 stand-ins, placed beside the harness where FinalizeOutputs looks.
    $script:SummaryParams = 'param($JsonFile, $HtmlFile, $Title, $TenantId, $Version, $ExtractionRunTime, $ReportingRunTime, $PhaseTimings, $PlatOS, $ConsumptionFile)'
    $script:SummaryWrites = $script:SummaryParams + [Environment]::NewLine + 'Set-Content -LiteralPath $HtmlFile -Value ''<html></html>'''

    # Stand-ins for the Azure-facing steps of a full run: discovery returns two disks and
    # one AVD host pool, and the collector step turns the disks into one collector.
    $script:RunStubs = @'
function CheckVersion { }
function CheckCliRequirements { }
function CheckPowerShell { }
function GetSubscriptionsData { }
function ResourceInventoryLoop
{
    $Global:Resources += @(
        [pscustomobject]@{ id = ('/subscriptions/{0}/resourcegroups/rg-app/providers/microsoft.compute/disks/disk-01' -f $DocsGuid); name = 'disk-01'; type = 'microsoft.compute/disks' }
        [pscustomobject]@{ id = ('/subscriptions/{0}/resourcegroups/rg-app/providers/microsoft.compute/disks/disk-02' -f $DocsGuid); name = 'disk-02'; type = 'microsoft.compute/disks' }
    )
}
function ResourceInventoryAvd
{
    $Global:Resources += @(
        [pscustomobject]@{ id = ('/subscriptions/{0}/resourcegroups/rg-avd/providers/microsoft.desktopvirtualization/hostpools/pool-01' -f $DocsGuid); name = 'pool-01'; type = 'microsoft.desktopvirtualization/hostpools' }
    )
}
function CreateMetricsJob { }
function ProcessMetricsResult { }
function CreateResourceJobs
{
    $Global:SmaResources = New-Object PSObject
    $Disks = @($Global:Resources | Where-Object { $_.type -eq 'microsoft.compute/disks' } | ForEach-Object { [ordered]@{ Name = $_.name } })
    $Global:SmaResources | Add-Member -MemberType NoteProperty -Name 'Disks' -Value $Disks
}
function GetResorceConsumption { }
function Get-AzContext { }
'@

    # Summary.ps1 stand-in that also records whether the collector data is still held
    # while the report is built.
    $script:SummaryRecordsState = $script:SummaryWrites + [Environment]::NewLine + @'
[pscustomobject]@{ ResourcesReleased = ($null -eq $Global:Resources); SmaResourcesReleased = ($null -eq $Global:SmaResources) } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path -Parent $HtmlFile) 'report-state.json')
'@

    # Runs the real script flow, from the setup block to the end, once per entry of $Runs,
    # all in ONE child pwsh process and in-process (`&`), as the wrappers call
    # ResourceInventory.ps1. Each entry is script text that may override the stubs above.
    # Returns, per run, the exit code, any error that escaped, and the globals left behind.
    function Invoke-InventoryRun
    {
        param([string]$Name, [string[]]$Runs)

        $CaseDir = Join-Path $script:TmpRoot $Name
        $Q = { param($s) "'" + $s.Replace("'", "''") + "'" }
        $RunFiles = @()
        for ($i = 0; $i -lt $Runs.Count; $i++)
        {
            $RunDir = Join-Path $CaseDir ('run{0}' -f $i)
            New-Item -ItemType Directory -Path (Join-Path $RunDir 'Extension') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $RunDir 'Extension/Summary.ps1') -Value $script:SummaryRecordsState -Encoding utf8

            $Harness = @(
                '$ErrorActionPreference = ''silentlycontinue'''
                ('. {0}' -f (& $Q $script:CommonFunctions))
                ('. {0}' -f (& $Q $script:InventoryFunctions))
                'function GetLocalVersion { ''1.2.3'' }'
                'function Write-RdaShareableDiagnosticsLog { $null }'
                ('$Global:DefaultPath = {0}' -f (& $Q ($RunDir + [IO.Path]::DirectorySeparatorChar)))
                '$Global:CurrentDateTime = ''test'''
                ('$DocsGuid = {0}' -f (& $Q $script:DocsGuid))
                '$ReportName = ''ResourcesReport'''
                '$SkipMetrics = [switch]$true'
                '$SkipConsumption = [switch]$true'
                '$Obfuscate = [switch]$false'
                '$RunAllSubs = [switch]$false'
                $script:RunStubs
                $script:VariablesText
                $script:InitializeInventoryProcessingText
                $script:ProcessResourceResultText
                $script:FinalizeOutputsText
                $script:RunInventorySetupFlowText
                $script:ExecuteInventoryProcessingFlowText
                $Runs[$i]
                $script:RunText
            ) -join [Environment]::NewLine
            $RunFile = Join-Path $RunDir 'harness.ps1'
            Set-Content -LiteralPath $RunFile -Value $Harness -Encoding utf8
            $RunFiles += $RunFile
        }

        $ResultsFile = Join-Path $CaseDir 'results.json'
        $Driver = @(
            ('$RunFiles = @({0})' -f ((@($RunFiles | ForEach-Object { & $Q $_ })) -join ', '))
            '$Results = foreach ($RunFile in $RunFiles)'
            '{'
            '    $global:LASTEXITCODE = 0'
            '    $Escaped = $null'
            '    try { & $RunFile *> $null } catch { $Escaped = $_.Exception.Message }'
            '    $RunDir = Split-Path -Parent $RunFile'
            '    $Inventory = Join-Path $RunDir ''Inventory_ResourcesReport_test.json'''
            '    $ReportState = Join-Path $RunDir ''report-state.json'''
            '    [pscustomobject]@{'
            '        ExitCode             = $LASTEXITCODE'
            '        AzAccountsLoaded     = [bool](Get-Module -Name Az.Accounts)'
            '        Escaped              = $Escaped'
            '        ResourceCount        = $Global:ResourceCount'
            '        ResourcesReleased    = ($null -eq $Global:Resources)'
            '        SmaResourcesReleased = ($null -eq $Global:SmaResources)'
            '        Inventory            = if (Test-Path -LiteralPath $Inventory) { Get-Content -LiteralPath $Inventory -Raw | ConvertFrom-Json } else { $null }'
            '        ReportState          = if (Test-Path -LiteralPath $ReportState) { Get-Content -LiteralPath $ReportState -Raw | ConvertFrom-Json } else { $null }'
            '    }'
            '}'
            ('ConvertTo-Json -InputObject @($Results) -Depth 6 | Set-Content -LiteralPath {0}' -f (& $Q $ResultsFile))
        ) -join [Environment]::NewLine
        $DriverFile = Join-Path $CaseDir 'driver.ps1'
        Set-Content -LiteralPath $DriverFile -Value $Driver -Encoding utf8

        $Output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $DriverFile 2>&1 | Out-String
        if (-not (Test-Path -LiteralPath $ResultsFile)) { throw "The run driver wrote no results. Output:`n$Output" }
        return @(Get-Content -LiteralPath $ResultsFile -Raw | ConvertFrom-Json)
    }

    # Runs one wrapper call site (its try block, lifted out of the wrapper) in a child pwsh
    # process against a stub ResourceInventory.ps1 that leaves behind what the real script
    # does once a run that found three resources has finished. Returns the count rows the
    # call site recorded.
    function Invoke-WrapperCallSite
    {
        param([string]$Name, [string]$WrapperFile, [int]$Index)

        $CaseDir = Join-Path $script:TmpRoot $Name
        New-Item -ItemType Directory -Path $CaseDir -Force | Out-Null
        $Q = { param($s) "'" + $s.Replace("'", "''") + "'" }

        Set-Content -LiteralPath (Join-Path $CaseDir 'ResourceInventory.ps1') -Encoding utf8 -Value @(
            'param($TenantID, $SubscriptionID, [switch]$RunAllSubs)'
            '$Global:Resources = $null'
            '$Global:SmaResources = $null'
            '$Global:ResourceCount = 3'
        )

        $Harness = @(
            ('. {0}' -f (& $Q $script:CommonFunctions))
            ('. {0}' -f (& $Q (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')))
            '$ScriptRoot = $PSScriptRoot'
            ('$TenantID = {0}' -f (& $Q $script:DocsGuid))
            ('$Sub = [pscustomobject]@{{ Name = ''sub-a''; Id = {0} }}' -f (& $Q $script:DocsGuid))
            '$SubId = $Sub.Id'
            '$SubName = $Sub.Name'
            '$Tag = ''[stream-0]'''
            '$StreamId = 0'
            '$InventoryPassthrough = @{}'
            '$SubResourceCounts = @()'
            '$ResourceCounts = @()'
            '$CompletedIds = @()'
            '$Completed = @()'
            '$FailedAttempts = @()'
            '$ResumeStateFile = Join-Path $PSScriptRoot ''resume-state.json'''
            '$StreamStateFile = Join-Path $PSScriptRoot ''stream-state.json'''
            $script:WrapperCallSites[$WrapperFile][$Index]
            '[pscustomobject]@{ Counts = @(@($SubResourceCounts) + @($ResourceCounts)) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PSScriptRoot ''result.json'')'
        ) -join [Environment]::NewLine
        $HarnessFile = Join-Path $CaseDir 'harness.ps1'
        Set-Content -LiteralPath $HarnessFile -Value $Harness -Encoding utf8

        $Output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $HarnessFile 2>&1 | Out-String
        $ResultFile = Join-Path $CaseDir 'result.json'
        if (-not (Test-Path -LiteralPath $ResultFile)) { throw "The call-site harness wrote no result. Output:`n$Output" }
        $Result = Get-Content -LiteralPath $ResultFile -Raw | ConvertFrom-Json
        [pscustomobject]@{ Counts = @($Result.Counts); Output = $Output }
    }

    $script:SavedGlobals = @{}
    foreach ($Name in 'SmaResources', 'JsonFile', 'Version', 'ErrorLogFile')
    {
        $script:SavedGlobals[$Name] = Get-Variable -Scope Global -Name $Name -ValueOnly -ErrorAction SilentlyContinue
    }
}

AfterAll {
    foreach ($Name in $script:SavedGlobals.Keys)
    {
        Set-Variable -Scope Global -Name $Name -Value $script:SavedGlobals[$Name]
    }
    if ($script:TmpRoot -and (Test-Path -LiteralPath $script:TmpRoot))
    {
        Get-ChildItem -LiteralPath $script:TmpRoot -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:TmpRoot -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Write-InventoryJson' {

    BeforeAll {
        . $script:InventoryFunctions
        if (-not (Get-Command -Name 'Write-InventoryJson' -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Expected function 'Write-InventoryJson' to be defined by $script:InventoryFunctions, but it was not."
        }

        # An empty folder of its own, so a test can check every file the writer left behind.
        function New-WriterCaseDir
        {
            $Dir = Join-Path $script:TmpRoot ('writer_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            return $Dir
        }
        function Get-WriterCaseFiles([string]$Dir)
        {
            return @(Get-ChildItem -LiteralPath $Dir -Force | ForEach-Object { $_.Name } | Sort-Object)
        }
        # The bytes the previous ProcessResourceResult pipeline wrote for $Inventory.
        function Get-ReferenceBytes($Inventory)
        {
            $ReferenceFile = Join-Path $script:TmpRoot ('reference_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
            $Inventory | ConvertTo-Json -depth 100 -compress 3>$null | Out-File $ReferenceFile
            return [System.IO.File]::ReadAllBytes($ReferenceFile)
        }
        # Same as the fixture, with a collector after the first one whose value ConvertTo-Json
        # rejects (a dictionary key that is not a string), so the write fails part-way.
        function New-FailingInventoryFixture
        {
            $Inv = New-Object PSObject
            $Inv | Add-Member -MemberType NoteProperty -Name 'Disks' -Value @([ordered]@{ Name = 'disk-01'; SizeGB = 64 })
            $Inv | Add-Member -MemberType NoteProperty -Name 'Broken' -Value @(@{ 1 = 'not a string key' })
            $Inv | Add-Member -MemberType NoteProperty -Name 'Version' -Value '1.2.3'
            return $Inv
        }
    }

    It 'writes bytes identical to the whole-document ConvertTo-Json | Out-File output and leaves only that file' {
        $Inventory = New-InventoryFixture
        $Dir = New-WriterCaseDir
        $Path = Join-Path $Dir 'writer-new.json'
        Write-InventoryJson -InputObject $Inventory -Path $Path 3>$null

        $New = [System.IO.File]::ReadAllBytes($Path)
        $Reference = Get-ReferenceBytes $Inventory
        $New.Length | Should -BeGreaterThan 0
        [Convert]::ToBase64String($New) | Should -BeExactly ([Convert]::ToBase64String($Reference))
        Get-WriterCaseFiles $Dir | Should -Be @('writer-new.json') -Because 'no temporary file is left behind'

        $Parsed = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
        @($Parsed.PSObject.Properties.Name) | Should -Be @('VirtualMachines', 'Disks', 'StorageAccounts', 'KeyVaults', 'Deep', 'Version')
        $Parsed.Version | Should -Be '1.2.3'
    }

    It 'keeps a one-element collector as a JSON array and writes no BOM' {
        $Path = Join-Path $script:TmpRoot 'writer-shape.json'
        Write-InventoryJson -InputObject (New-InventoryFixture) -Path $Path 3>$null

        $Bytes = [System.IO.File]::ReadAllBytes($Path)
        $Bytes[0] | Should -Be ([byte][char]'{')
        $Text = [System.Text.Encoding]::UTF8.GetString($Bytes)
        $Text | Should -Match '"StorageAccounts":\[\{'
        $Text | Should -Match '"Disks":\[\],'
        $Text | Should -Match 'Zürich team'
        $Text.EndsWith('}' + [Environment]::NewLine) | Should -BeTrue
    }

    It 'never serialises the whole inventory in a single ConvertTo-Json call' {
        $script:MockInventory = New-InventoryFixture
        $Path = Join-Path $script:TmpRoot 'writer-percollector.json'

        # Pass-through mock, so calls can be inspected and the file is still written.
        Mock -CommandName ConvertTo-Json -MockWith $script:PassThroughConvertToJson

        Write-InventoryJson -InputObject $script:MockInventory -Path $Path 3>$null

        Should -Invoke -CommandName ConvertTo-Json -Times 1
        Should -Invoke -CommandName ConvertTo-Json -Times 0 -Exactly -ParameterFilter { [object]::ReferenceEquals($InputObject, $script:MockInventory) } -Because 'each collector is serialised separately so the whole document is never one in-memory string'
        (Get-Item -LiteralPath $Path).Length | Should -BeGreaterThan 0
    }

    It 'resolves a relative path against the PowerShell location, as Out-File does' {
        $LocationDir = Join-Path $script:TmpRoot 'location'
        New-Item -ItemType Directory -Path $LocationDir -Force | Out-Null
        $SavedProcessDir = [Environment]::CurrentDirectory
        try
        {
            [Environment]::CurrentDirectory = $script:TmpRoot
            Push-Location -LiteralPath $LocationDir
            Write-InventoryJson -InputObject (New-InventoryFixture) -Path 'relative.json' 3>$null
        }
        finally
        {
            Pop-Location
            [Environment]::CurrentDirectory = $SavedProcessDir
        }

        Test-Path -LiteralPath (Join-Path $LocationDir 'relative.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:TmpRoot 'relative.json') | Should -BeFalse
    }

    It 'throws when the file cannot be created' {
        $Path = Join-Path $script:TmpRoot 'no-such-dir/inventory.json'
        { Write-InventoryJson -InputObject (New-InventoryFixture) -Path $Path 3>$null } | Should -Throw
        Test-Path -LiteralPath $Path | Should -BeFalse
    }

    It 'leaves no inventory file and no temporary file when a collector fails to serialise (ErrorActionPreference <Preference>)' -ForEach @(
        @{ Preference = 'Continue' }
        @{ Preference = 'SilentlyContinue' }
    ) {
        # SilentlyContinue is what ResourceInventory.ps1 runs with outside -Debug.
        $Dir = New-WriterCaseDir
        $Path = Join-Path $Dir 'Inventory_test.json'
        $ErrorActionPreference = $Preference

        { Write-InventoryJson -InputObject (New-FailingInventoryFixture) -Path $Path 3>$null } | Should -Throw '*Keys must be strings*'

        $ErrorActionPreference = 'Continue'
        Get-WriterCaseFiles $Dir | Should -BeNullOrEmpty -Because 'a failed write must not leave a cut-off inventory or its temporary file'
        if (Test-Path -LiteralPath "/proc/$PID/fd")
        {
            @(Get-ChildItem -LiteralPath "/proc/$PID/fd" -ErrorAction SilentlyContinue | Where-Object { [string]$_.LinkTarget -like "$Dir*" }).Count | Should -Be 0 -Because 'the file is closed before it is removed'
        }
    }

    It 'leaves no temporary file when the finished file cannot be moved into place' {
        $Dir = New-WriterCaseDir
        $Path = Join-Path $Dir 'Inventory_test.json'
        New-Item -ItemType Directory -Path $Path | Out-Null

        { Write-InventoryJson -InputObject (New-InventoryFixture) -Path $Path 3>$null } | Should -Throw

        Get-WriterCaseFiles $Dir | Should -Be @('Inventory_test.json')
        Test-Path -LiteralPath $Path -PathType Container | Should -BeTrue -Because 'what was at the path is left as it was'
    }

    It 'replaces an existing file at the path' {
        $Inventory = New-InventoryFixture
        $Dir = New-WriterCaseDir
        $Path = Join-Path $Dir 'Inventory_test.json'
        # Longer than the new content, so a leftover tail would show.
        [System.IO.File]::WriteAllText($Path, ('old content ' * 1000))

        Write-InventoryJson -InputObject $Inventory -Path $Path 3>$null

        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) | Should -BeExactly ([Convert]::ToBase64String((Get-ReferenceBytes $Inventory)))
        Get-WriterCaseFiles $Dir | Should -Be @('Inventory_test.json')
    }
}

Describe 'ProcessResourceResult' {

    BeforeAll {
        . $script:CommonFunctions
        . $script:InventoryFunctions
        . ([scriptblock]::Create($script:ProcessResourceResultText))
        $Global:ErrorLogFile = $null
        $Global:Version = '1.2.3'
    }

    It 'writes the same bytes as before without serialising the whole inventory in one call' {
        $Global:SmaResources = New-InventoryFixture -WithoutVersion
        $Global:JsonFile = Join-Path $script:TmpRoot 'process-new.json'

        Mock -CommandName ConvertTo-Json -MockWith $script:PassThroughConvertToJson

        ProcessResourceResult 6>$null 3>$null

        Should -Invoke -CommandName ConvertTo-Json -Times 1
        Should -Invoke -CommandName ConvertTo-Json -Times 0 -Exactly -ParameterFilter { [object]::ReferenceEquals($InputObject, $Global:SmaResources) } -Because 'the inventory is written one collector at a time'

        # The previous pipeline on the same object, which ProcessResourceResult has given its Version.
        $ReferenceFile = Join-Path $script:TmpRoot 'process-reference.json'
        $Global:SmaResources | & $script:RealConvertToJson -Depth 100 -Compress 3>$null | Out-File $ReferenceFile
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Global:JsonFile)) | Should -BeExactly ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ReferenceFile)))
        $Global:SmaResources.Version | Should -Be '1.2.3'
    }
}

Describe 'Collector data is released once the inventory is written' {

    It 'keeps the discovered resource count after a normal run' {
        $R = @(Invoke-InventoryRun -Name 'count-normal' -Runs @(''))

        $R[0].Escaped | Should -BeNullOrEmpty
        $R[0].ExitCode | Should -Be 0
        $R[0].ResourceCount | Should -Be 3 -Because 'two disks and one AVD host pool were discovered'
        $R[0].AzAccountsLoaded | Should -BeFalse -Because 'the run harness stubs every Az cmdlet, so it never loads Az.Accounts or reaches the network'
    }

    It 'releases the collector output and the discovery rows after the write and before the report step' {
        $R = @(Invoke-InventoryRun -Name 'release' -Runs @(''))

        $R[0].Escaped | Should -BeNullOrEmpty
        $R[0].ExitCode | Should -Be 0
        $R[0].Inventory | Should -Not -BeNullOrEmpty -Because 'the inventory is written before the data is released'
        @($R[0].Inventory.Disks).Count | Should -Be 2
        $R[0].ReportState.ResourcesReleased | Should -BeTrue -Because 'the report step must not have to share memory with the discovery rows'
        $R[0].ReportState.SmaResourcesReleased | Should -BeTrue -Because 'the report step must not have to share memory with the collector output'
        $R[0].ResourcesReleased | Should -BeTrue
        $R[0].SmaResourcesReleased | Should -BeTrue
    }

    It 'resets the count when a later run in the same process exits before discovery' {
        # A plain Exit (wrong -OutputDirectory, no Azure CLI, ...) returns exit code 0,
        # so the wrappers treat the run as complete and read its count.
        $R = @(Invoke-InventoryRun -Name 'count-early-exit' -Runs @('', 'function CheckPowerShell { Exit }'))

        $R[0].ResourceCount | Should -Be 3
        $R[1].ExitCode | Should -Be 0
        $R[1].ResourceCount | Should -Be 0 -Because 'the previous run''s count must not be reported for this run'
    }

    It 'keeps the count of a later run that stopped after discovery' {
        $Second = @'
function ResourceInventoryLoop { $Global:Resources += @([pscustomobject]@{ id = 'disk-09'; name = 'disk-09'; type = 'microsoft.compute/disks' }) }
function ResourceInventoryAvd { }
function CreateResourceJobs { throw 'collector step failed' }
'@
        $R = @(Invoke-InventoryRun -Name 'count-stopped' -Runs @('', $Second))

        $R[0].ResourceCount | Should -Be 3
        $R[1].Escaped | Should -Match 'collector step failed'
        $R[1].ResourceCount | Should -Be 1 -Because 'the count belongs to the run that just stopped, not the one before it'
    }

    Context 'Azure session read after the release' {

        BeforeAll {
            # Offsets in ResourceInventory.ps1. Every search starts at the release line inside
            # ExecuteInventoryProcessing, so the billing function's definition above it is never matched.
            $script:ScriptText = [System.IO.File]::ReadAllText($script:InventoryScript)
            $Tokens = $null
            $ParseErrors = $null
            $script:ScriptAst = [System.Management.Automation.Language.Parser]::ParseInput($script:ScriptText, [ref]$Tokens, [ref]$ParseErrors)
            $Fn = $script:ScriptAst.FindAll({
                    param($Node)
                    $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'ExecuteInventoryProcessing'
                }, $false) | Select-Object -First 1
            if ($null -eq $Fn) { throw 'ExecuteInventoryProcessing was not found in ResourceInventory.ps1.' }

            $Release = [regex]::new('(?m)^[ \t]*\$Global:Resources = \$null[ \t]*\r?$').Match($script:ScriptText, $Fn.Extent.StartOffset)
            if (-not $Release.Success -or $Release.Index -ge $Fn.Extent.EndOffset) { throw 'The release line ($Global:Resources = $null) was not found in ExecuteInventoryProcessing.' }
            $script:ReleaseStart = $Release.Index
            $script:ReleaseEnd = $Release.Index + $Release.Length

            $Billing = [regex]::new('(?m)^[ \t]*GetResorceConsumption[ \t]*\r?$').Match($script:ScriptText, $script:ReleaseEnd)
            if (-not $Billing.Success -or $Billing.Index -ge $Fn.Extent.EndOffset) { throw 'The billing call (GetResorceConsumption) was not found after the release line.' }
            $script:BillingStart = $Billing.Index

            $script:FirstCollect = $script:ScriptText.IndexOf('[System.GC]::Collect()', $script:ReleaseEnd, [System.StringComparison]::Ordinal)
            $script:ReadPattern = [regex]::new('(?m)^[ \t]*\$null = Get-AzContext -ErrorAction SilentlyContinue[ \t]*\r?$')
        }

        It 'reads the Azure context after the release and before the release collects and before the billing step' {
            $Read = $script:ReadPattern.Match($script:ScriptText, $script:ReleaseEnd)

            $Read.Success | Should -BeTrue -Because 'the release frees nothing until an Az cmdlet replaces the stream handlers the last collector left in the Azure session'
            $script:FirstCollect | Should -BeGreaterThan $script:ReleaseEnd -Because 'the release collects after setting the globals to $null'
            $Read.Index | Should -BeLessThan $script:FirstCollect -Because 'the read must come before the release collects, or the rows are still held when it runs'
            $Read.Index | Should -BeLessThan $script:BillingStart -Because 'the read must not depend on the billing step, which -SkipConsumption leaves out'
        }

        It 'reads the Azure context exactly once between the release and the billing step' {
            $Between = $script:ScriptText.Substring($script:ReleaseEnd, $script:BillingStart - $script:ReleaseEnd)

            $script:ReadPattern.Matches($Between).Count | Should -Be 1
        }

        It 'frees the rows a piped Az call in a collector kept, where a call that is not an Az cmdlet does not' -Skip:(-not $script:HasAzAccounts) {
            # The shipped try block, lifted out of ResourceInventory.ps1.
            $Tries = @($script:ScriptAst.FindAll({
                        param($Node)
                        $Node -is [System.Management.Automation.Language.TryStatementAst] -and
                        $Node.Extent.StartOffset -gt $script:ReleaseEnd -and $Node.Extent.EndOffset -lt $script:BillingStart
                    }, $true))
            $Tries.Count | Should -Be 1 -Because 'one guarded Azure session read follows the release'

            $CaseDir = Join-Path $script:TmpRoot ('session-read_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $ChildHome = Join-Path $CaseDir 'home'
            New-Item -ItemType Directory -Path (Join-Path $ChildHome '.Azure') -Force | Out-Null
            # Az usage data collection off, so the child sends nothing.
            Set-Content -LiteralPath (Join-Path $ChildHome '.Azure/AzurePSDataCollectionProfile.json') -Value '{"enableAzureDataCollection":false}' -Encoding ascii
            $BlockFile = Join-Path $CaseDir 'block.ps1'
            Set-Content -LiteralPath $BlockFile -Value $Tries[0].Extent.Text -Encoding utf8
            $ResultFile = Join-Path $CaseDir 'result.json'

            # Runs in its own process: a fresh Azure session with no context, autosave off.
            # The fake collector keeps the real four-parameter contract and pipes its Az call
            # into a script-block filter, as the VM size lookup does.
            $Child = @'
param([string]$BlockFile, [string]$ResultFile)
$ErrorActionPreference = 'silentlycontinue'
Import-Module -Name Az.Accounts -ErrorAction Stop -WarningAction SilentlyContinue
$null = Disable-AzContextAutosave -Scope Process
function Write-Log { param($Message, [switch]$NoConsole, [switch]$ToDebugLog) }
function Invoke-Plain { $null = 1 }
$Block = [scriptblock]::Create([System.IO.File]::ReadAllText($BlockFile))
$Settle = { [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect() }
$Collector = {
    param($Sub, $Resources, $Task, $ResourceIdDictionary)
    $VirtualMachines = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachines' }
    if ($Task -eq 'Processing' -and $VirtualMachines)
    {
        $null = Get-AzContext -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ }
    }
    @($VirtualMachines).Count
}
function New-CollectorRound
{
    $List = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt 2000; $i++)
    {
        $List.Add([pscustomobject]@{ TYPE = 'microsoft.compute/virtualmachines'; location = 'westeurope'; Blob = ('{0:d6}' -f $i).PadRight(20000, [char](65 + ($i % 26))) })
    }
    $List.Add([pscustomobject]@{ TYPE = 'microsoft.compute/disks'; location = 'westeurope'; Blob = 'disk' })
    $Rows = $List.ToArray()
    $List = $null
    $null = & $Collector -Sub @() -Resources $Rows -Task 'Processing' -ResourceIdDictionary $null
    [WeakReference]::new($Rows[0])
}
# A fresh profile's first Az cmdlet can stay referenced for a moment; a real run signs in first.
$null = Get-AzContext -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
$Rounds = foreach ($Round in 1..3)
{
    $Weak = New-CollectorRound
    Invoke-Plain
    & $Settle
    $HeldAfterPlain = $Weak.IsAlive
    $null = Get-Date
    & $Settle
    $HeldAfterNonAz = $Weak.IsAlive
    & $Block
    $Watch = [System.Diagnostics.Stopwatch]::StartNew()
    & $Settle
    while ($Weak.IsAlive -and $Watch.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 250; & $Settle }
    [pscustomobject]@{ Round = $Round; HeldAfterPlain = $HeldAfterPlain; HeldAfterNonAz = $HeldAfterNonAz; HeldAfterBlock = $Weak.IsAlive }
}
[pscustomobject]@{ AzAccountsLoaded = [bool](Get-Module -Name Az.Accounts); Rounds = @($Rounds) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultFile
'@
            $ChildFile = Join-Path $CaseDir 'child.ps1'
            Set-Content -LiteralPath $ChildFile -Value $Child -Encoding utf8

            # A local port with nothing listening, so any web request the child makes fails at once.
            $Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $Listener.Start()
            $ClosedPort = $Listener.LocalEndpoint.Port
            $Listener.Stop()
            $AzModule = Get-Module -ListAvailable -Name Az.Accounts | Sort-Object Version -Descending | Select-Object -First 1
            $ModuleRoot = Split-Path (Split-Path $AzModule.ModuleBase -Parent) -Parent
            $ChildEnv = @{
                HOME         = $ChildHome
                USERPROFILE  = $ChildHome
                PSModulePath = ($ModuleRoot, (Join-Path $PSHOME 'Modules')) -join [System.IO.Path]::PathSeparator
                HTTPS_PROXY  = ('http://127.0.0.1:{0}' -f $ClosedPort)
                HTTP_PROXY   = ('http://127.0.0.1:{0}' -f $ClosedPort)
            }
            $SavedEnv = @{}
            foreach ($Key in $ChildEnv.Keys) { $SavedEnv[$Key] = [Environment]::GetEnvironmentVariable($Key) }
            try
            {
                foreach ($Key in $ChildEnv.Keys) { [Environment]::SetEnvironmentVariable($Key, $ChildEnv[$Key]) }
                $Output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $ChildFile -BlockFile $BlockFile -ResultFile $ResultFile 2>&1 | Out-String
            }
            finally
            {
                foreach ($Key in $SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($Key, $SavedEnv[$Key]) }
            }
            Test-Path -LiteralPath $ResultFile | Should -BeTrue -Because "the child process writes its result. Output:`n$Output"
            $Result = Get-Content -LiteralPath $ResultFile -Raw | ConvertFrom-Json

            $Result.AzAccountsLoaded | Should -BeTrue
            @($Result.Rounds).Count | Should -Be 3
            foreach ($Round in $Result.Rounds)
            {
                $Round.HeldAfterPlain | Should -BeTrue -Because "round $($Round.Round): the piped Az call keeps the collector's rows, or this test proves nothing"
                $Round.HeldAfterNonAz | Should -BeTrue -Because "round $($Round.Round): a statement that is not an Az cmdlet does not free them"
                $Round.HeldAfterBlock | Should -BeFalse -Because "round $($Round.Round): the session read after the release frees them"
            }
        }
    }
}

Describe 'Wrappers read the resource count from $Global:ResourceCount' {

    It 'records the inner script count at the <Label> call site' -ForEach @(
        @{ Label = 'sequential loop'; WrapperFile = 'Run-AllSubscriptions.ps1'; Index = 0 }
        @{ Label = 'single-subscription fallback'; WrapperFile = 'Run-AllSubscriptions.ps1'; Index = 1 }
        @{ Label = 'parallel stream worker'; WrapperFile = 'Run-AllSubscriptions.Stream.ps1'; Index = 0 }
    ) {
        $R = Invoke-WrapperCallSite -Name ('wrapper-{0}-{1}' -f [IO.Path]::GetFileNameWithoutExtension($WrapperFile), $Index) -WrapperFile $WrapperFile -Index $Index

        @($R.Counts).Count | Should -Be 1 -Because "one row is recorded for the subscription. Output:`n$($R.Output)"
        $R.Counts[0].Id | Should -Be $script:DocsGuid
        $R.Counts[0].Count | Should -Be 3 -Because 'the discovery rows are released by then, so the count comes from $Global:ResourceCount'
    }
}
