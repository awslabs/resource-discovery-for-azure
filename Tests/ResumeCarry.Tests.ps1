#
# A -Resume run of Run-AllSubscriptions.ps1 skips the subscriptions an earlier,
# interrupted run completed. Their reports must still be in the consolidated
# AllSubscriptions_ResourcesReport_<stamp>.zip, even though their per-subscription
# zips are older than this run's start time.
#
#   - The resume state records each completed subscription's report zip
#     (CompletedReports), and old state files without it still load.
#   - Get-ResumeCarriedReports carries a recorded zip only when it is usable and
#     of the same -Obfuscate mode; every malformed or unusable record is named.
#   - The verification count, the consolidated zip and MainSummary.html include
#     the carried reports.
#   - Both paths, end to end without Azure: the sequential loop and the
#     post-processing are lifted from the wrapper's AST and run as written; the
#     parallel path runs the real stream worker with its Az context import mocked,
#     then the wrapper's stranded-state fold and per-stream aggregation as written.
#   A stand-in ResourceInventory.ps1 writes one report folder + zip per call.
#
# Run with: Invoke-Pester ./Tests/ResumeCarry.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('ResumeCarryTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null

    # A report folder and zip as the inner script leaves them under the inventory root.
    function script:New-TestReport
    {
        param([string]$Root, [string]$Stamp, [string]$SubName = 'Sub')
        $Folder = Join-Path $Root ('ResourcesReport' + $Stamp)
        $Stage = Join-Path $Root ('.stage-' + $Stamp)
        New-Item -ItemType Directory -Path $Folder, $Stage -Force | Out-Null
        $Inv = @{ VirtualMachines = @(@{ Name = 'vm1'; Subscription = $SubName }, @{ Name = 'vm2'; Subscription = $SubName }) } | ConvertTo-Json -Depth 4
        Set-Content -LiteralPath (Join-Path $Stage ('Inventory_ResourcesReport_{0}.json' -f $Stamp)) -Value $Inv -Encoding utf8
        Set-Content -LiteralPath (Join-Path $Stage ('ResourcesReport_{0}.html' -f $Stamp)) -Value '<html></html>' -Encoding utf8
        $Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        Copy-Item -Path (Join-Path $Stage '*') -Destination $Folder
        Remove-Item -LiteralPath $Stage -Recurse -Force
        return $Zip
    }

    # Make a report look like it was written by an earlier run.
    function script:Set-ReportAge
    {
        param([string]$Zip, [datetime]$When)
        $Folder = Split-Path -Path $Zip -Parent
        Get-ChildItem -LiteralPath $Folder -File | ForEach-Object { $_.LastWriteTime = $When }
        (Get-Item -LiteralPath $Folder).LastWriteTime = $When
    }

    function script:Get-InnerZipNames
    {
        param([string]$OuterZip)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($OuterZip)
        try { return @($Archive.Entries | Where-Object { $_.FullName -like 'ResourcesReport_*.zip' } | ForEach-Object { $_.FullName }) }
        finally { $Archive.Dispose() }
    }

    # Stand-in for ResourceInventory.ps1: one report per call under the test's
    # inventory root, and the globals the wrapper reads afterwards. The resource
    # count is set both as the list and as the count, so the stand-in reports one
    # resource whichever of the two the wrapper reads.
    $script:FakeRoot = Join-Path $script:TestBase 'fake-tool'
    New-Item -ItemType Directory -Path $script:FakeRoot -Force | Out-Null
    $FakeInner = @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
$Root = $Global:RdaCarryTestRoot
$Stamp = (Get-Date -Format 'yyyyMMddHHmmssfff') + $SubscriptionID
$Folder = Join-Path $Root ('ResourcesReport' + $Stamp)
New-Item -ItemType Directory -Path $Folder -Force | Out-Null
$Stage = Join-Path $Root ('.stage-' + $Stamp)
New-Item -ItemType Directory -Path $Stage -Force | Out-Null
Set-Content -LiteralPath (Join-Path $Stage ('Inventory_ResourcesReport_{0}.json' -f $Stamp)) -Value ('{"VirtualMachines":[{"Name":"vm","Subscription":"' + $SubscriptionID + '"}]}') -Encoding utf8
Set-Content -LiteralPath (Join-Path $Stage ('ResourcesReport_{0}.html' -f $Stamp)) -Value '<html></html>' -Encoding utf8
$Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
Copy-Item -Path (Join-Path $Stage '*') -Destination $Folder
Remove-Item -LiteralPath $Stage -Recurse -Force
$Global:ZipOutputFile = $Zip
$Global:Resources = @(1)
$Global:ResourceCount = 1
'@
    Set-Content -LiteralPath (Join-Path $script:FakeRoot 'ResourceInventory.ps1') -Value $FakeInner -Encoding utf8

    # --- Wrapper code lifted from its AST and run as written ------------------
    $Tokens = $null
    $ParseErrors = $null
    $script:WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$Tokens, [ref]$ParseErrors)
    $Top = @($Ast.EndBlock.Statements)

    # The sequential loop: the body of `if ($ParallelStreams -le 1)`.
    $SeqIf = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq '$ParallelStreams -le 1' }, $true))
    if ($SeqIf.Count -ne 1) { throw "Expected one 'if (`$ParallelStreams -le 1)' in the wrapper, found $($SeqIf.Count)." }
    $SeqText = $SeqIf[0].Clauses[0].Item2.Extent.Text -replace '\$PSScriptRoot', '$FakeScriptRoot'
    $script:SequentialBlock = [scriptblock]::Create(
        "param(`$FakeScriptRoot, `$Subscriptions, `$Resume, `$CompletedIds, `$FailedAttempts, `$CompletedReports, `$InventoryRoot, `$ResumeStateFile, `$TenantID, `$Obfuscate)`n" +
        "`$SkippedCount = 0; `$SkippedSubscriptions = @(); `$SubResourceCounts = @(); `$FailedSubscriptions = @(); `$DiagFile = `$null; `$InventoryPassthrough = @{ ConcurrencyLimit = 6 }; if (`$Obfuscate) { `$InventoryPassthrough['Obfuscate'] = `$true }`n" +
        ". " + $SeqText + "`n" +
        "[pscustomobject]@{ SkippedSubscriptions = @(`$SkippedSubscriptions); SubResourceCounts = @(`$SubResourceCounts); CompletedIds = @(`$CompletedIds); CompletedReports = @(`$CompletedReports) }")

    # The startup fold of per-stream state left by an interrupted parallel run.
    $Fold = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$Resume -or $ResumeFailedOnly' })
    if ($Fold.Count -ne 1) { throw "Expected one top-level 'if (`$Resume -or `$ResumeFailedOnly)' in the wrapper, found $($Fold.Count)." }
    $script:FoldBlock = [scriptblock]::Create(
        "param(`$InventoryRoot, `$TenantID, `$ResumeStateFile, `$CompletedIds, `$FailedAttempts, `$CompletedReports)`n`$Resume = `$true; `$ResumeFailedOnly = `$false`n" +
        $Fold[0].Extent.Text + "`n[pscustomobject]@{ CompletedIds = @(`$CompletedIds); CompletedReports = @(`$CompletedReports) }")

    # The parallel parent's aggregation of stream summaries and per-stream state:
    # the orchestration try-body from its summary loop to its end.
    $Orch = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.TryStatementAst] -and $args[0].Body.Extent.Text -match [regex]::Escape("`$WorkerScript = Join-Path `$PSScriptRoot 'Run-AllSubscriptions.Stream.ps1'") }, $true))
    if ($Orch.Count -ne 1) { throw "Expected one stream-orchestration try block in the wrapper, found $($Orch.Count)." }
    $Body = @($Orch[0].Body.Statements)
    $AggStart = -1
    for ($i = 0; $i -lt $Body.Count; $i++)
    {
        if ($Body[$i] -is [System.Management.Automation.Language.ForEachStatementAst] -and $Body[$i].Condition.Extent.Text -eq '$StreamSummaries' -and $Body[$i].Body.Extent.Text -match 'ResourceCounts') { $AggStart = $i; break }
    }
    if ($AggStart -lt 0) { throw 'Expected the stream-summary aggregation loop in the wrapper.' }
    $AggText = (@($Body[$AggStart..($Body.Count - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n")
    $script:AggregateBlock = [scriptblock]::Create(
        "param(`$StreamSummaries, `$InventoryRoot, `$TenantID, `$ResumeStateFile, `$CompletedIds, `$FailedAttempts, `$CompletedReports)`n" +
        "`$SkippedSubscriptions = @(); `$SubResourceCounts = @(); `$FailedSubscriptions = @(); `$DiagFile = `$null`n" +
        $AggText + "`n[pscustomobject]@{ SkippedSubscriptions = @(`$SkippedSubscriptions); SubResourceCounts = @(`$SubResourceCounts); CompletedIds = @(`$CompletedIds); CompletedReports = @(`$CompletedReports); FailedSubscriptions = @(`$FailedSubscriptions) }")

    # Post-processing shared by both paths: from "All subscriptions processed!"
    # through the MainSummary.html build. Exit-Wrapper is replaced so a failed
    # verification surfaces as an exception instead of ending the test host.
    $From = -1
    $To = -1
    for ($i = 0; $i -lt $Top.Count; $i++)
    {
        if ($From -lt 0 -and $Top[$i].Extent.Text -eq 'Write-Host "All subscriptions processed!" -ForegroundColor Green') { $From = $i }
        if ($From -ge 0 -and $Top[$i] -is [System.Management.Automation.Language.IfStatementAst] -and $Top[$i].Extent.Text -match 'New-RdaAllSubHtmlSummary -RunOutputDirectory') { $To = $i; break }
    }
    if ($From -lt 0 -or $To -lt 0) { throw 'Expected the post-processing statements (verification, consolidation, main summary) in the wrapper.' }
    $PostText = (@($Top[$From..$To] | ForEach-Object { $_.Extent.Text }) -join "`n") -replace '\$PSScriptRoot', '$RealScriptRoot'
    $script:PostBlock = [scriptblock]::Create(
        "param(`$RealScriptRoot, `$InventoryRoot, `$RunStartTime, `$SubResourceCounts, `$SkippedSubscriptions, `$CompletedReports, `$Resume, `$Obfuscate, `$ResumeStateFile, `$TenantID)`n" +
        "function Exit-Wrapper { param([int]`$Code) throw ('Exit-Wrapper ' + `$Code) }`n" +
        "`$WrapperTranscriptStarted = `$false; `$FailedSubscriptions = @(); `$Detailed = `$false`n" +
        $PostText + "`n" +
        "[pscustomobject]@{ OuterZipFile = `$OuterZipFile; MainSummaryFile = `$MainSummaryFile; Uncarried = @(`$UncarriedSkipped) }")

    function script:Invoke-Post
    {
        param($Root, $Since, $ThisRun, $Skipped, $Reports, [bool]$Obfuscate = $false)
        $Out = @(& $script:PostBlock $script:RepoRoot $Root $Since @($ThisRun) @($Skipped) @($Reports) $true $Obfuscate (Join-Path $Root '.resume-state-t.json') 't' 6>&1)
        $Result = $Out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['OuterZipFile'] } | Select-Object -Last 1
        $Text = @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        return [pscustomobject]@{ Result = $Result; Text = $Text }
    }

    # The recorded reports read straight from the state file, so the end-to-end
    # tests run unchanged against a version that has no reader for them.
    function script:Read-StateReports
    {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
        return @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).CompletedReports | Where-Object { $null -ne $_ })
    }

    function script:New-CaseRoot
    {
        $Root = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        return $Root
    }
}

AfterAll {
    Remove-Variable -Name RdaCarryTestRoot -Scope Global -ErrorAction SilentlyContinue
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe 'Resume state: the report zip of each completed subscription' {
    BeforeEach { $script:Root = script:New-CaseRoot }

    It 'records one report per completed id, the last one given winning, none for an id not completed' {
        $State = Join-Path $script:Root '.resume-state-t.json'
        $Reports = @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'A'; Zip = 'old/a.zip'; Obfuscated = $false },
            [pscustomobject]@{ Id = 'sub-a'; Name = 'A'; Zip = 'new/a.zip'; Obfuscated = $false },
            [pscustomobject]@{ Id = 'sub-x'; Name = 'X'; Zip = 'x/x.zip'; Obfuscated = $false })
        Save-CompletedSubscriptionIds -Path $State -Tenant 't' -Ids @('sub-a') -Reports $Reports
        $Read = @(Get-CompletedReports -Path $State -Tenant 't')
        $Read.Count | Should -Be 1
        $Read[0].Zip | Should -Be 'new/a.zip'
        $Read[0].Obfuscated | Should -BeOfType [bool]
        @(Get-CompletedSubscriptionIds -Path $State -Tenant 't') | Should -Be @('sub-a')
    }

    It 'a state file written by an older version (no CompletedReports) still loads' {
        $State = Join-Path $script:Root '.resume-state-t.json'
        @{ TenantID = 't'; CompletedSubscriptionIds = @('sub-a'); FailedAttempts = @(); LastUpdated = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -Path $State -Encoding utf8
        @(Get-CompletedSubscriptionIds -Path $State -Tenant 't') | Should -Be @('sub-a')
        @(Get-CompletedReports -Path $State -Tenant 't').Count | Should -Be 0
    }

    It 'Test-ResumeStateWithoutReports is true only for a state file of this tenant that has no CompletedReports key' {
        $State = Join-Path $script:Root '.resume-state-t.json'
        Test-ResumeStateWithoutReports -Path $State -Tenant 't' | Should -BeFalse -Because 'there is no state file'
        @{ TenantID = 't'; CompletedSubscriptionIds = @('sub-a'); FailedAttempts = @() } | ConvertTo-Json | Set-Content -LiteralPath $State
        Test-ResumeStateWithoutReports -Path $State -Tenant 't' | Should -BeTrue
        Test-ResumeStateWithoutReports -Path $State -Tenant 'other' | Should -BeFalse -Because 'the file is for another tenant'
        Save-CompletedSubscriptionIds -Path $State -Tenant 't' -Ids @('sub-a')
        (Get-Content -LiteralPath $State -Raw) | Should -Match '"CompletedReports":\s*\[\s*\]'
        Test-ResumeStateWithoutReports -Path $State -Tenant 't' | Should -BeFalse -Because 'an empty CompletedReports list is not a missing key'
        '{"TenantID":"t","CompletedSubscriptionIds":["sub-a"],"CompletedReports":null}' | Set-Content -LiteralPath $State
        Test-ResumeStateWithoutReports -Path $State -Tenant 't' | Should -BeFalse -Because 'the key is present, even with a null value'
        '{ not json' | Set-Content -LiteralPath $State
        Test-ResumeStateWithoutReports -Path $State -Tenant 't' | Should -BeFalse -Because 'an unparseable file reads as no state'
    }

    It 'an unparseable state file, or one for another tenant, reads as no reports' {
        $State = Join-Path $script:Root '.resume-state-t.json'
        Set-Content -Path $State -Value '{ "TenantID": "t", "CompletedReports": [ {' -Encoding utf8
        @(Get-CompletedReports -Path $State -Tenant 't').Count | Should -Be 0
        @{ TenantID = 'other'; CompletedReports = @(@{ Id = 'sub-a'; Zip = 'a.zip'; Obfuscated = $false }) } | ConvertTo-Json -Depth 4 | Set-Content -Path $State -Encoding utf8
        @(Get-CompletedReports -Path $State -Tenant 't').Count | Should -Be 0
    }

    It 'records with a missing, empty, numeric or object Id, and non-object entries, are ignored when saved' {
        $State = Join-Path $script:Root '.resume-state-t.json'
        $Reports = @(
            'just text', 42, $null,
            [pscustomobject]@{ Name = 'no id'; Zip = 'a.zip'; Obfuscated = $false },
            [pscustomobject]@{ Id = ''; Zip = 'a.zip'; Obfuscated = $false },
            [pscustomobject]@{ Id = 7; Zip = 'a.zip'; Obfuscated = $false },
            [pscustomobject]@{ Id = [pscustomobject]@{ x = 1 }; Zip = 'a.zip'; Obfuscated = $false },
            [pscustomobject]@{ Id = 'sub-a'; Name = 'A'; Zip = 'good/a.zip'; Obfuscated = $false })
        Save-CompletedSubscriptionIds -Path $State -Tenant 't' -Ids @('sub-a', '7') -Reports $Reports
        $Read = @(Get-CompletedReports -Path $State -Tenant 't')
        $Read.Count | Should -Be 1
        $Read[0].Zip | Should -Be 'good/a.zip'
    }

    It 'New-CompletedReportRecord stores the zip relative to the inventory root, with the -Obfuscate mode' {
        $Zip = script:New-TestReport -Root $script:Root -Stamp '1aaaa'
        $Rec = New-CompletedReportRecord -InventoryRoot $script:Root -Id 'sub-a' -Name 'A' -ZipPath $Zip -Obfuscated $true
        $Rec.Zip | Should -Be (Join-Path 'ResourcesReport1aaaa' 'ResourcesReport_1aaaa.zip')
        $Rec.Obfuscated | Should -BeTrue
        $Rec.Id | Should -Be 'sub-a'
    }

    It 'New-CompletedReportRecord records nothing for no path, a path with no file, or a zip outside the inventory root' {
        New-CompletedReportRecord -InventoryRoot $script:Root -Id 'sub-a' -Name 'A' -ZipPath $null -Obfuscated $false | Should -BeNullOrEmpty
        New-CompletedReportRecord -InventoryRoot $script:Root -Id 'sub-a' -Name 'A' -ZipPath (Join-Path $script:Root 'none.zip') -Obfuscated $false | Should -BeNullOrEmpty
        $Outside = script:New-TestReport -Root (script:New-CaseRoot) -Stamp '1bbbb'
        New-CompletedReportRecord -InventoryRoot $script:Root -Id 'sub-a' -Name 'A' -ZipPath $Outside -Obfuscated $false | Should -BeNullOrEmpty
    }

    It 'per-stream state keeps Reports, and an older stream file without them reads as none' {
        # Write-StreamState / Write-Stream read these from the caller's scope, as in the worker.
        Set-Variable -Name TenantID -Value 't'
        Set-Variable -Name StreamId -Value '0'
        Set-Variable -Name Tag -Value '[stream-0]'
        $Path = Join-Path $script:Root '.resume-state-t-stream-0.json'
        Write-StreamState -Path $Path -Completed @('sub-a') -FailedAttempts @() -Reports @([pscustomobject]@{ Id = 'sub-a'; Name = 'A'; Zip = 'a/a.zip'; Obfuscated = $false })
        $Read = Read-StreamState -Path $Path
        @($Read.Reports).Count | Should -Be 1
        @($Read.Reports)[0].Zip | Should -Be 'a/a.zip'
        @{ Tenant = 't'; StreamId = '0'; Completed = @('sub-a'); FailedAttempts = @() } | ConvertTo-Json | Set-Content -Path $Path -Encoding utf8
        @((Read-StreamState -Path $Path).Reports).Count | Should -Be 0
    }
}

Describe 'Get-ResumeCarriedReports: which earlier reports a -Resume run carries' {
    BeforeEach {
        $script:Root = script:New-CaseRoot
        $script:Zip = script:New-TestReport -Root $script:Root -Stamp '2aaaa'
        $script:Rel = Join-Path 'ResourcesReport2aaaa' 'ResourcesReport_2aaaa.zip'
        $script:SubA = [pscustomobject]@{ Id = 'sub-a'; Name = 'A' }
    }

    It 'carries a usable zip recorded with the same -Obfuscate mode (<Mode>)' -TestCases @(@{ Mode = $false }, @{ Mode = $true }) {
        param($Mode)
        $R = Get-ResumeCarriedReports -SkippedSubscriptions @($script:SubA) -Reports @([pscustomobject]@{ Id = 'sub-a'; Name = 'A'; Zip = $script:Rel; Obfuscated = $Mode }) -InventoryRoot $script:Root -Obfuscated $Mode
        @($R.Carried).Count | Should -Be 1
        @($R.Missing).Count | Should -Be 0
        $R.Carried[0].Zip | Should -Be ([System.IO.Path]::GetFullPath($script:Zip))
        $R.Carried[0].Folder | Should -Be 'ResourcesReport2aaaa'
    }

    It 'names a skipped subscription with no record, as from a state written by an older version' {
        $R = Get-ResumeCarriedReports -SkippedSubscriptions @($script:SubA) -Reports @() -InventoryRoot $script:Root -Obfuscated $false
        @($R.Carried).Count | Should -Be 0
        $R.Missing[0].Id | Should -Be 'sub-a'
        $R.Missing[0].Reason | Should -Match 'older version'
    }

    It 'names a record whose path is <Label>' -TestCases @(
        @{ Label = 'absent'; Zip = $null; Pattern = 'missing or not text' },
        @{ Label = 'empty'; Zip = ''; Pattern = 'missing or not text' },
        @{ Label = 'a number'; Zip = 12; Pattern = 'missing or not text' },
        @{ Label = 'rooted'; Zip = '/etc/x.zip'; Pattern = 'not a path inside the inventory root' },
        @{ Label = 'climbing out with ..'; Zip = '../elsewhere/x.zip'; Pattern = 'not a path inside the inventory root' },
        @{ Label = 'not a .zip'; Zip = 'ResourcesReport2aaaa/ResourcesReport_2aaaa.html'; Pattern = 'not a report zip' },
        @{ Label = 'a de-obfuscated copy'; Zip = 'ResourcesReport2aaaa/ResourcesReport_2aaaa_revealed.zip'; Pattern = 'not a report zip' },
        @{ Label = 'no longer on disk'; Zip = 'ResourcesReport9zzzz/ResourcesReport_9zzzz.zip'; Pattern = 'no longer on disk' }
    ) {
        param($Label, $Zip, $Pattern)
        $Rec = [pscustomobject]@{ Id = 'sub-a'; Name = 'A'; Obfuscated = $false }
        if ($Label -ne 'absent') { $Rec | Add-Member -NotePropertyName Zip -NotePropertyValue $Zip }
        $R = Get-ResumeCarriedReports -SkippedSubscriptions @($script:SubA) -Reports @($Rec) -InventoryRoot $script:Root -Obfuscated $false
        @($R.Carried).Count | Should -Be 0
        $R.Missing[0].Reason | Should -Match ([regex]::Escape($Pattern))
    }

    It 'names a record whose -Obfuscate mode is <Label>' -TestCases @(
        @{ Label = 'absent'; Value = $null; Absent = $true },
        @{ Label = 'the text true'; Value = 'true'; Absent = $false },
        @{ Label = 'the number 1'; Value = 1; Absent = $false }
    ) {
        param($Label, $Value, $Absent)
        $Rec = [pscustomobject]@{ Id = 'sub-a'; Name = 'A'; Zip = $script:Rel }
        if (-not $Absent) { $Rec | Add-Member -NotePropertyName Obfuscated -NotePropertyValue $Value }
        $R = Get-ResumeCarriedReports -SkippedSubscriptions @($script:SubA) -Reports @($Rec) -InventoryRoot $script:Root -Obfuscated $false
        @($R.Carried).Count | Should -Be 0
        $R.Missing[0].Reason | Should -Match 'not true/false'
    }

    It 'names a recorded file that is not a zip, and a zip with no entries' {
        $Bad = Join-Path $script:Root 'ResourcesReport3bbbb'
        New-Item -ItemType Directory -Path $Bad -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Bad 'ResourcesReport_3bbbb.zip') -Value 'this is not a zip archive' -Encoding utf8
        $Empty = Join-Path $script:Root 'ResourcesReport3cccc'
        New-Item -ItemType Directory -Path $Empty -Force | Out-Null
        ([System.IO.Compression.ZipFile]::Open((Join-Path $Empty 'ResourcesReport_3cccc.zip'), [System.IO.Compression.ZipArchiveMode]::Create)).Dispose()
        $Subs = @([pscustomobject]@{ Id = 'sub-b'; Name = 'B' }, [pscustomobject]@{ Id = 'sub-c'; Name = 'C' })
        $Reports = @(
            [pscustomobject]@{ Id = 'sub-b'; Name = 'B'; Zip = 'ResourcesReport3bbbb/ResourcesReport_3bbbb.zip'; Obfuscated = $false },
            [pscustomobject]@{ Id = 'sub-c'; Name = 'C'; Zip = 'ResourcesReport3cccc/ResourcesReport_3cccc.zip'; Obfuscated = $false })
        $R = Get-ResumeCarriedReports -SkippedSubscriptions $Subs -Reports $Reports -InventoryRoot $script:Root -Obfuscated $false
        @($R.Carried).Count | Should -Be 0
        ($R.Missing | Where-Object Id -eq 'sub-b').Reason | Should -Match 'cannot be opened as a zip'
        ($R.Missing | Where-Object Id -eq 'sub-c').Reason | Should -Match 'is empty'
    }

    It 'never mixes modes: a <Was> report is not carried into a <Now> run' -TestCases @(
        @{ Was = 'non-obfuscated'; WasObf = $false; Now = 'obfuscated'; NowObf = $true },
        @{ Was = 'obfuscated'; WasObf = $true; Now = 'non-obfuscated'; NowObf = $false }
    ) {
        param($Was, $WasObf, $Now, $NowObf)
        $R = Get-ResumeCarriedReports -SkippedSubscriptions @($script:SubA) -Reports @([pscustomobject]@{ Id = 'sub-a'; Name = 'A'; Zip = $script:Rel; Obfuscated = $WasObf }) -InventoryRoot $script:Root -Obfuscated $NowObf
        @($R.Carried).Count | Should -Be 0
        $R.Missing[0].Reason | Should -Match 'never mixes'
    }

    It 'the last record for a subscription wins, and a subscription listed twice is decided once' {
        $Reports = @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'A'; Zip = 'ResourcesReport9zzzz/ResourcesReport_9zzzz.zip'; Obfuscated = $false },
            [pscustomobject]@{ Id = 'sub-a'; Name = 'A'; Zip = $script:Rel; Obfuscated = $false })
        $R = Get-ResumeCarriedReports -SkippedSubscriptions @($script:SubA, $script:SubA) -Reports $Reports -InventoryRoot $script:Root -Obfuscated $false
        @($R.Carried).Count | Should -Be 1
        @($R.Missing).Count | Should -Be 0
    }

    It 'Join-CarriedReportZips adds each carried zip once, after this run''s' {
        $ThisRun = Get-Item -LiteralPath (script:New-TestReport -Root $script:Root -Stamp '2bbbb')
        $Carried = @([pscustomobject]@{ Id = 'sub-a'; Zip = $script:Zip })
        $All = @(Join-CarriedReportZips -Zips @($ThisRun) -CarriedReports $Carried)
        $All.Count | Should -Be 2
        $All[0].FullName | Should -Be $ThisRun.FullName
        @(Join-CarriedReportZips -Zips @($ThisRun, (Get-Item -LiteralPath $script:Zip)) -CarriedReports $Carried).Count | Should -Be 2
    }
}

Describe 'Exit code when an earlier report is missing from the consolidated zip' {
    It 'is 2, ahead of the auth (3), collector (4) and combined (5) codes' {
        Get-WrapperExitCode -AuthSkipped $false -CollectorsFailed $false -ReportsMissing $true | Should -Be 2
        Get-WrapperExitCode -AuthSkipped $true -CollectorsFailed $true -ReportsMissing $true | Should -Be 2
        Get-WrapperExitCode -AuthSkipped $true -CollectorsFailed $false | Should -Be 3
    }

    It 'the wrapper passes the uncarried list to the exit code and prints the FAILED banner before its transcript stops' {
        $Src = Get-Content -LiteralPath $script:WrapperPath -Raw
        $Src | Should -Match ([regex]::Escape('Get-WrapperExitCode -AuthSkipped $AuthSkipped -CollectorsFailed $CollectorsFailed -ReportsMissing (@($UncarriedSkipped).Count -gt 0)'))
        $Lines = Get-Content -LiteralPath $script:WrapperPath
        $Banner = ($Lines | Select-String -SimpleMatch 'FAILED (earlier report not carried) =' | Select-Object -First 1).LineNumber
        $Stop = ($Lines | Select-String -SimpleMatch 'Stop-Transcript on normal completion failed' | Select-Object -First 1).LineNumber
        $Banner | Should -Not -BeNullOrEmpty
        $Banner | Should -BeLessThan $Stop
    }
}

Describe 'MainSummary.html covers the carried subscriptions' {
    It 'includes a named report folder older than -SinceTime, and still leaves out an unnamed old one' {
        $Root = script:New-CaseRoot
        $Old = script:New-TestReport -Root $Root -Stamp '4aaaa' -SubName 'Carried Sub'
        $Other = script:New-TestReport -Root $Root -Stamp '4bbbb' -SubName 'Unrelated Sub'
        script:Set-ReportAge -Zip $Old -When (Get-Date).AddHours(-3)
        script:Set-ReportAge -Zip $Other -When (Get-Date).AddHours(-3)
        $Since = (Get-Date).AddMinutes(-1)
        $null = script:New-TestReport -Root $Root -Stamp '4cccc' -SubName 'This Run Sub'
        $Html = Join-Path $Root 'MainSummary.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $Root -HtmlFile $Html -SinceTime $Since -IncludeFolders @('ResourcesReport4aaaa') 6>$null
        $Text = Get-Content -LiteralPath $Html -Raw
        $Text | Should -Match 'Carried Sub'
        $Text | Should -Match 'This Run Sub'
        $Text | Should -Not -Match 'Unrelated Sub'
    }
}

Describe 'Sequential path, end to end: interrupted run, then -Resume' {
    BeforeEach {
        $script:Root = script:New-CaseRoot
        $Global:RdaCarryTestRoot = $script:Root
        $global:LASTEXITCODE = 0
        $script:State = Join-Path $script:Root '.resume-state-t.json'
        $script:A = [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' }
        $script:B = [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B' }

        # The earlier run completed sub-a, then was interrupted before it consolidated.
        $script:Run1 = & $script:SequentialBlock $script:FakeRoot @($script:A) $false @() @() @() $script:Root $script:State 't' $false 6>$null
        Get-ChildItem -LiteralPath $script:Root -Directory -Filter 'ResourcesReport*' | ForEach-Object {
            $Zip = Get-ChildItem -LiteralPath $_.FullName -Filter '*.zip' | Select-Object -First 1
            script:Set-ReportAge -Zip $Zip.FullName -When (Get-Date).AddHours(-2)
        }
        $script:Since = Get-Date
    }

    It 'the interrupted run recorded sub-a and its zip in the resume state' {
        @(Get-CompletedSubscriptionIds -Path $script:State -Tenant 't') | Should -Be @('sub-a')
        $Rec = @(script:Read-StateReports -Path $script:State)
        $Rec.Count | Should -Be 1
        $Rec[0].Id | Should -Be 'sub-a'
        Test-Path -LiteralPath (Join-Path $script:Root $Rec[0].Zip) | Should -BeTrue
    }

    It 'the -Resume run ships both reports and the verification counts the carried one' {
        $Run2 = & $script:SequentialBlock $script:FakeRoot @($script:A, $script:B) $true @(Get-CompletedSubscriptionIds -Path $script:State -Tenant 't') @() @(script:Read-StateReports -Path $script:State) $script:Root $script:State 't' $false 6>$null
        $Post = script:Invoke-Post -Root $script:Root -Since $script:Since -ThisRun $Run2.SubResourceCounts -Skipped $Run2.SkippedSubscriptions -Reports $Run2.CompletedReports
        @(script:Get-InnerZipNames -OuterZip $Post.Result.OuterZipFile).Count | Should -Be 2 -Because 'the subscription completed by the interrupted run must not drop out of the consolidated zip'
        @($Run2.SkippedSubscriptions | ForEach-Object Id) | Should -Be @('sub-a')
        @($Run2.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-b')
        ($Post.Text -join "`n") | Should -Match 'verification: OK \(2 zip\(s\) match 1 successful sub\(s\) this run \+ 1 carried'
        @($Post.Result.Uncarried).Count | Should -Be 0
        (Get-Content -LiteralPath $Post.Result.MainSummaryFile -Raw) | Should -Match 'sub-a'
    }

    It 'a skipped subscription whose recorded zip is gone is named, and the gate does not say OK' {
        Get-ChildItem -LiteralPath $script:Root -Recurse -Filter 'ResourcesReport_*.zip' | Remove-Item -Force
        $Run2 = & $script:SequentialBlock $script:FakeRoot @($script:A, $script:B) $true @(Get-CompletedSubscriptionIds -Path $script:State -Tenant 't') @() @(script:Read-StateReports -Path $script:State) $script:Root $script:State 't' $false 6>$null
        $Post = script:Invoke-Post -Root $script:Root -Since $script:Since -ThisRun $Run2.SubResourceCounts -Skipped $Run2.SkippedSubscriptions -Reports $Run2.CompletedReports
        @($Post.Result.Uncarried | ForEach-Object Id) | Should -Be @('sub-a')
        ($Post.Text -join "`n") | Should -Match 'verification: INCOMPLETE'
        ($Post.Text -join "`n") | Should -Not -Match 'verification: OK'
        @(script:Get-InnerZipNames -OuterZip $Post.Result.OuterZipFile).Count | Should -Be 1
    }

    It 'a -Resume run with -Obfuscate does not carry the earlier non-obfuscated report' {
        $Run2 = & $script:SequentialBlock $script:FakeRoot @($script:A, $script:B) $true @(Get-CompletedSubscriptionIds -Path $script:State -Tenant 't') @() @(script:Read-StateReports -Path $script:State) $script:Root $script:State 't' $true 6>$null
        $Post = script:Invoke-Post -Root $script:Root -Since $script:Since -ThisRun $Run2.SubResourceCounts -Skipped $Run2.SkippedSubscriptions -Reports $Run2.CompletedReports -Obfuscate $true
        @($Post.Result.Uncarried | ForEach-Object Id) | Should -Be @('sub-a')
        $Post.Result.Uncarried[0].Reason | Should -Match 'never mixes'
    }
}

Describe 'Parallel path, end to end: interrupted stream, then -Resume' {
    BeforeAll {
        Mock Import-Module -ParameterFilter { $Name -eq 'Az.Accounts' } -MockWith { }
        Mock Disable-AzContextAutosave -MockWith { }
        Mock Import-AzContext -MockWith { }
        $script:WorkerPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1'
        function script:Invoke-Worker
        {
            param($Root, [string[]]$Ids, [string[]]$Names, [switch]$Resume)
            $WorkerArgs = @{
                TenantID           = 't'
                StreamId           = '0'
                InventoryRoot      = $Root
                ScriptRoot         = $script:FakeRoot
                AzContextPath      = (Join-Path $Root 'ctx.json')
                StreamSummaryPath  = (Join-Path $Root '.rda-stream-0-summary.json')
                StreamFailuresPath = (Join-Path $Root 'failures-stream-0.log')
                SubscriptionIds    = $Ids
                SubscriptionNames  = $Names
                ConcurrencyLimit   = 6
            }
            if ($Resume) { $WorkerArgs.Resume = $true }
            & $script:WorkerPath @WorkerArgs 6>$null
            return (Get-Content -LiteralPath $WorkerArgs.StreamSummaryPath -Raw | ConvertFrom-Json)
        }
    }

    It 'the stream records its reports, a resumed stream reports what it skipped, and the bundle has every subscription' {
        $Root = script:New-CaseRoot
        $Global:RdaCarryTestRoot = $Root
        $State = Join-Path $Root '.resume-state-t.json'

        # Earlier run: stream 0 completed sub-a, then the parent was interrupted before merging.
        $null = script:Invoke-Worker -Root $Root -Ids @('sub-a') -Names @('Sub A')
        $StreamFile = Join-Path $Root '.resume-state-t-stream-0.json'
        $Run1Reports = @((Get-Content -LiteralPath $StreamFile -Raw | ConvertFrom-Json).Reports | Where-Object { $null -ne $_ } | ForEach-Object Id)
        Get-ChildItem -LiteralPath $Root -Directory -Filter 'ResourcesReport*' | ForEach-Object {
            script:Set-ReportAge -Zip (Get-ChildItem -LiteralPath $_.FullName -Filter '*.zip' | Select-Object -First 1).FullName -When (Get-Date).AddHours(-2)
        }
        Remove-Item -LiteralPath (Join-Path $Root '.rda-stream-0-summary.json') -Force

        # -Resume: the parent folds the stranded stream state, as written.
        $Folded = & $script:FoldBlock $Root 't' $State @() @() @() 6>$null
        $HealedReports = @(script:Read-StateReports -Path $State | ForEach-Object Id)

        $Since = Get-Date
        $Summary = script:Invoke-Worker -Root $Root -Ids @('sub-a', 'sub-b') -Names @('Sub A', 'Sub B') -Resume

        # The parent aggregates the stream summary and merges per-stream state, as written.
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = (Join-Path $Root '.rda-stream-0-summary.json'); FailuresPath = (Join-Path $Root 'failures-stream-0.log'); SubCount = 2 })
        $Agg = & $script:AggregateBlock $Streams $Root 't' $State @($Folded.CompletedIds) @() @($Folded.CompletedReports) 6>$null
        $Post = script:Invoke-Post -Root $Root -Since $Since -ThisRun $Agg.SubResourceCounts -Skipped $Agg.SkippedSubscriptions -Reports $Agg.CompletedReports

        @(script:Get-InnerZipNames -OuterZip $Post.Result.OuterZipFile).Count | Should -Be 2 -Because 'the subscription the interrupted stream completed must not drop out of the consolidated zip'
        ($Post.Text -join "`n") | Should -Match 'verification: OK \(2 zip\(s\) match 1 successful sub\(s\) this run \+ 1 carried'
        $Run1Reports | Should -Be @('sub-a') -Because 'the stream records the zip of the subscription it completed'
        @($Folded.CompletedIds) | Should -Be @('sub-a')
        $HealedReports | Should -Be @('sub-a') -Because 'the healed unified state keeps the stranded report'
        @($Summary.Skipped | ForEach-Object Id) | Should -Be @('sub-a')
        @($Agg.SkippedSubscriptions | ForEach-Object Id) | Should -Be @('sub-a')
        @($Agg.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-b')
        @(script:Read-StateReports -Path $State | ForEach-Object Id | Sort-Object) | Should -Be @('sub-a', 'sub-b')
    }
}

Describe 'A failed attempt, or a run that leaves no zip, clears the completed record of a subscription an earlier run completed' {
    BeforeAll {
        Mock Import-Module -ParameterFilter { $Name -eq 'Az.Accounts' } -MockWith { }
        Mock Disable-AzContextAutosave -MockWith { }
        Mock Import-AzContext -MockWith { }

        # The same stand-in, except that it throws for the ids in $Global:RdaCarryTestFailIds,
        # and for the ids in $Global:RdaCarryTestNoZipIds ends without writing a zip, as the
        # real script does when collection stops early: exit code 0, the resources counted,
        # $Global:ZipOutputFile naming a zip that is not on disk.
        $script:FailRoot = Join-Path $script:TestBase 'fake-tool-fail'
        New-Item -ItemType Directory -Path $script:FailRoot -Force | Out-Null
        $Parts = (Get-Content -LiteralPath (Join-Path $script:FakeRoot 'ResourceInventory.ps1') -Raw) -split "`r?`n", 2
        $NoZipLine = "if (@(`$Global:RdaCarryTestNoZipIds) -contains `$SubscriptionID) { `$Global:ZipOutputFile = Join-Path `$Global:RdaCarryTestRoot ('ResourcesReport_' + `$SubscriptionID + '.zip'); `$Global:Resources = @(1); `$Global:ResourceCount = 1; return }`n"
        $FailInner = $Parts[0] + "`nif (@(`$Global:RdaCarryTestFailIds) -contains `$SubscriptionID) { throw 'stand-in failure for this subscription' }`n" + $NoZipLine + $Parts[1]
        Set-Content -LiteralPath (Join-Path $script:FailRoot 'ResourceInventory.ps1') -Value $FailInner -Encoding utf8

        # The sequential catch writes its failure log under $HOME/InventoryReports;
        # point that at a scratch folder.
        $Global:RdaCarryTestHome = Join-Path $script:TestBase 'home'
        New-Item -ItemType Directory -Path $Global:RdaCarryTestHome -Force | Out-Null
        $script:SeqBlock = [scriptblock]::Create(($script:SequentialBlock.ToString() -replace '\$HOME\b', '$Global:RdaCarryTestHome'))

        # The one-subscription fallback of the parallel path, lifted as written.
        $Tokens = $null
        $ParseErrors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$Tokens, [ref]$ParseErrors)
        $OneIf = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq '$StreamCount -le 1' }, $true))
        if ($OneIf.Count -ne 1) { throw "Expected one 'if (`$StreamCount -le 1)' in the wrapper, found $($OneIf.Count)." }
        $script:FallbackBlock = [scriptblock]::Create(
            "param(`$FakeScriptRoot, `$Subscriptions, `$CompletedIds, `$FailedAttempts, `$CompletedReports, `$InventoryRoot, `$ResumeStateFile, `$TenantID)`n" +
            "`$StreamCount = 1; `$Obfuscate = `$false; `$SubResourceCounts = @(); `$FailedSubscriptions = @(); `$DiagFile = `$null; `$InventoryPassthrough = @{ ConcurrencyLimit = 6 }`n" +
            ($OneIf[0].Extent.Text -replace '\$PSScriptRoot', '$FakeScriptRoot'))

        function script:Invoke-FailWorker
        {
            param($Root, [string[]]$Ids, [string[]]$Names)
            $WorkerArgs = @{
                TenantID           = 't'
                StreamId           = '0'
                InventoryRoot      = $Root
                ScriptRoot         = $script:FailRoot
                AzContextPath      = (Join-Path $Root 'ctx.json')
                StreamSummaryPath  = (Join-Path $Root '.rda-stream-0-summary.json')
                StreamFailuresPath = (Join-Path $Root 'failures-stream-0.log')
                SubscriptionIds    = $Ids
                SubscriptionNames  = $Names
                ConcurrencyLimit   = 6
            }
            & (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1') @WorkerArgs 6>$null
        }

        function script:Read-State
        {
            param([string]$Path)
            return [pscustomobject]@{
                Completed = @(Get-CompletedSubscriptionIds -Path $Path -Tenant 't')
                Failed    = @(Get-FailedAttempts -Path $Path -Tenant 't' | Where-Object { $null -ne $_ } | ForEach-Object Id)
                Reports   = @(script:Read-StateReports -Path $Path)
            }
        }

        # The earlier run: sequential, completes sub-a, then is interrupted. Its report is 2 hours old.
        function script:Invoke-EarlierRun
        {
            param($Root, $State)
            $null = & $script:SeqBlock $script:FailRoot @($script:A) $false @() @() @() $Root $State 't' $false 6>$null
            Get-ChildItem -LiteralPath $Root -Directory -Filter 'ResourcesReport*' | ForEach-Object {
                script:Set-ReportAge -Zip (Get-ChildItem -LiteralPath $_.FullName -Filter '*.zip' | Select-Object -First 1).FullName -When (Get-Date).AddHours(-2)
            }
        }

        # The post-processing of a run that ends at the output verification: the lines
        # it printed up to that point and the exit code it ended with.
        function script:Invoke-PostUntilExit
        {
            param($Root, $Since, $ThisRun)
            $Lines = [System.Collections.Generic.List[string]]::new()
            $Code = $null
            try
            {
                & $script:PostBlock $script:RepoRoot $Root $Since @($ThisRun) @() @() $false $false (Join-Path $Root '.resume-state-t.json') 't' 6>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.InformationRecord]) { $Lines.Add([string]$_.MessageData) } }
            }
            catch
            {
                if ($_.Exception.Message -match '^Exit-Wrapper (\d+)$') { $Code = [int]$Matches[1] } else { throw }
            }
            return [pscustomobject]@{ Text = @($Lines); ExitCode = $Code }
        }

        # Run 3: sequential -Resume over sub-a and sub-b, then the post-processing.
        function script:Invoke-ResumeRun
        {
            param($Root, $State)
            $Global:RdaCarryTestFailIds = @()
            $Global:RdaCarryTestNoZipIds = @()
            $Since = Get-Date
            $S = script:Read-State -Path $State
            $Run = & $script:SeqBlock $script:FailRoot @($script:A, $script:B) $true $S.Completed @(Get-FailedAttempts -Path $State -Tenant 't') $S.Reports $Root $State 't' $false 6>$null
            $Post = script:Invoke-Post -Root $Root -Since $Since -ThisRun $Run.SubResourceCounts -Skipped $Run.SkippedSubscriptions -Reports $Run.CompletedReports
            return [pscustomobject]@{ Run = $Run; Post = $Post }
        }
    }

    BeforeEach {
        $script:Root = script:New-CaseRoot
        $Global:RdaCarryTestRoot = $script:Root
        $Global:RdaCarryTestFailIds = @()
        $Global:RdaCarryTestNoZipIds = @()
        $global:LASTEXITCODE = 0
        $script:State = Join-Path $script:Root '.resume-state-t.json'
        $script:A = [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' }
        $script:B = [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B' }
        script:Invoke-EarlierRun -Root $script:Root -State $script:State
    }

    AfterAll {
        Remove-Variable -Name RdaCarryTestFailIds, RdaCarryTestNoZipIds, RdaCarryTestHome -Scope Global -ErrorAction SilentlyContinue
    }

    It 'sequential: a run without -Resume fails sub-a, and the next -Resume collects it again' {
        $Global:RdaCarryTestFailIds = @('sub-a')
        $S = script:Read-State -Path $script:State
        $null = & $script:SeqBlock $script:FailRoot @($script:A) $false $S.Completed @() $S.Reports $script:Root $script:State 't' $false 6>$null
        $After2 = script:Read-State -Path $script:State
        $R = script:Invoke-ResumeRun -Root $script:Root -State $script:State

        @($R.Run.SkippedSubscriptions | ForEach-Object Id) | Should -BeNullOrEmpty -Because 'the -Resume run must not skip a subscription whose latest attempt failed'
        ($R.Post.Text -join "`n") | Should -Not -Match 'Resume: carrying' -Because 'the earlier run''s report of sub-a is no longer its latest'
        @($R.Run.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-a', 'sub-b')
        ($R.Post.Text -join "`n") | Should -Match 'verification: OK \(2 zip\(s\) match 2 successful sub\(s\)\)'
        $After2.Completed | Should -BeNullOrEmpty -Because 'the latest attempt at sub-a failed'
        $After2.Reports | Should -BeNullOrEmpty
        $After2.Failed | Should -Be @('sub-a')
    }

    It 'parallel: a stream fails sub-a in a run without -Resume, the merge keeps the failure, and the next -Resume collects it again' {
        $Global:RdaCarryTestFailIds = @('sub-a')
        $S = script:Read-State -Path $script:State
        script:Invoke-FailWorker -Root $script:Root -Ids @('sub-a', 'sub-b') -Names @('Sub A', 'Sub B')
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = (Join-Path $script:Root '.rda-stream-0-summary.json'); FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 2 })
        $null = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed @(Get-FailedAttempts -Path $script:State -Tenant 't') $S.Reports 6>$null
        $After2 = script:Read-State -Path $script:State
        $R = script:Invoke-ResumeRun -Root $script:Root -State $script:State

        @($R.Run.SkippedSubscriptions | ForEach-Object Id) | Should -Be @('sub-b') -Because 'the -Resume run must not skip a subscription whose latest attempt failed'
        @($R.Run.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-a') -Because 'the -Resume run must collect sub-a again'
        ($R.Post.Text -join "`n") | Should -Match 'verification: OK \(2 zip\(s\) match 1 successful sub\(s\) this run \+ 1 carried'
        $After2.Completed | Should -Be @('sub-b') -Because 'the latest attempt at sub-a failed'
        $After2.Failed | Should -Be @('sub-a') -Because 'the merge of per-stream state must keep this run''s failure'
        @($After2.Reports | ForEach-Object Id) | Should -Be @('sub-b')
    }

    It 'one-subscription fallback: a failed attempt at sub-a clears its record, and the next -Resume collects it again' {
        $Global:RdaCarryTestFailIds = @('sub-a')
        $S = script:Read-State -Path $script:State
        $null = & $script:FallbackBlock $script:FailRoot @($script:A) $S.Completed @() $S.Reports $script:Root $script:State 't' 6>$null
        $After2 = script:Read-State -Path $script:State
        $R = script:Invoke-ResumeRun -Root $script:Root -State $script:State

        @($R.Run.SkippedSubscriptions | ForEach-Object Id) | Should -BeNullOrEmpty -Because 'the -Resume run must not skip a subscription whose latest attempt failed'
        @($R.Run.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-a', 'sub-b')
        $After2.Completed | Should -BeNullOrEmpty -Because 'the latest attempt at sub-a failed'
        $After2.Reports | Should -BeNullOrEmpty
        $After2.Failed | Should -Be @('sub-a')
    }

    It 'a stream that did not start leaves the earlier completion and report of its subscriptions as they were' {
        $S = script:Read-State -Path $script:State
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        @{ StreamId = '0'; Tenant = 't'; Status = 'failed-to-start'; Reason = 'stand-in'; Completed = @(); ResourceCounts = @()
            Failed = @(@{ Id = 'sub-a'; Name = 'Sub A'; Reason = 'stream did not start: Az context import failed' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 1 })
        $Agg = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed @() $S.Reports 6>$null

        @($Agg.CompletedIds) | Should -Be @('sub-a')
        @($Agg.CompletedReports | ForEach-Object Id) | Should -Be @('sub-a')
        @($Agg.FailedSubscriptions).Count | Should -Be 1
    }

    It 'sequential: a run without -Resume leaves no zip for sub-a, and the next -Resume collects it again' {
        $Run1Zip = Split-Path -Path (script:Read-State -Path $script:State).Reports[0].Zip -Leaf
        $Global:RdaCarryTestNoZipIds = @('sub-a')
        $S = script:Read-State -Path $script:State
        $Since2 = Get-Date
        $Run2 = & $script:SeqBlock $script:FailRoot @($script:A) $false $S.Completed @() $S.Reports $script:Root $script:State 't' $false 6>$null
        $Post2 = script:Invoke-PostUntilExit -Root $script:Root -Since $Since2 -ThisRun $Run2.SubResourceCounts
        $After2 = script:Read-State -Path $script:State
        $R = script:Invoke-ResumeRun -Root $script:Root -State $script:State

        $After2.Completed | Should -BeNullOrEmpty -Because 'the latest run of sub-a left no report'
        $After2.Reports | Should -BeNullOrEmpty
        $After2.Failed | Should -BeNullOrEmpty -Because 'a run that left no zip is not recorded as a failed attempt'
        $Post2.ExitCode | Should -Be 2 -Because 'the run that left no zip still ends at the output verification, as before'
        ($Post2.Text -join "`n") | Should -Match 'ERROR: Per-subscription output verification failed'
        @($R.Run.SkippedSubscriptions | ForEach-Object Id) | Should -BeNullOrEmpty -Because 'the -Resume run must not skip a subscription whose latest run left no report'
        ($R.Post.Text -join "`n") | Should -Not -Match 'Resume: carrying'
        @($R.Run.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-a', 'sub-b')
        ($R.Post.Text -join "`n") | Should -Match 'verification: OK \(2 zip\(s\) match 2 successful sub\(s\)\)'
        @(script:Get-InnerZipNames -OuterZip $R.Post.Result.OuterZipFile) | Should -Not -Contain $Run1Zip -Because 'the earlier run''s report of sub-a is no longer its latest'
    }

    It 'sequential: a run that leaves no zip keeps an earlier failed attempt of the subscription' {
        $Global:RdaCarryTestFailIds = @('sub-b')
        $S = script:Read-State -Path $script:State
        $null = & $script:SeqBlock $script:FailRoot @($script:B) $false $S.Completed @() $S.Reports $script:Root $script:State 't' $false 6>$null
        $Global:RdaCarryTestFailIds = @()
        $Global:RdaCarryTestNoZipIds = @('sub-b')
        $S = script:Read-State -Path $script:State
        $null = & $script:SeqBlock $script:FailRoot @($script:B) $false $S.Completed @(Get-FailedAttempts -Path $script:State -Tenant 't') $S.Reports $script:Root $script:State 't' $false 6>$null
        $After = script:Read-State -Path $script:State

        $After.Failed | Should -Be @('sub-b') -Because 'sub-b still has no report, so -ResumeFailedOnly must still retry it'
        $After.Completed | Should -Be @('sub-a')
    }

    It 'parallel: a stream leaves no zip for sub-a in a run without -Resume, the merge ends its completion, and the next -Resume collects it again' {
        $Global:RdaCarryTestNoZipIds = @('sub-a')
        $S = script:Read-State -Path $script:State
        script:Invoke-FailWorker -Root $script:Root -Ids @('sub-a', 'sub-b') -Names @('Sub A', 'Sub B')
        $Summary = Get-Content -LiteralPath (Join-Path $script:Root '.rda-stream-0-summary.json') -Raw | ConvertFrom-Json
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = (Join-Path $script:Root '.rda-stream-0-summary.json'); FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 2 })
        $Agg = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed @(Get-FailedAttempts -Path $script:State -Tenant 't') $S.Reports 6>$null
        $After2 = script:Read-State -Path $script:State
        $R = script:Invoke-ResumeRun -Root $script:Root -State $script:State

        $After2.Completed | Should -Be @('sub-b') -Because 'the latest run of sub-a left no report'
        @($After2.Reports | ForEach-Object Id) | Should -Be @('sub-b')
        $After2.Failed | Should -BeNullOrEmpty
        @($Summary.Completed) | Should -Be @('sub-b') -Because 'the stream does not count sub-a as completed either'
        @($Summary.NoReport | ForEach-Object Id) | Should -Be @('sub-a')
        @($Agg.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-a', 'sub-b') -Because 'sub-a still counts as collected this run, so the verification still sees its zip missing'
        @($R.Run.SkippedSubscriptions | ForEach-Object Id) | Should -Be @('sub-b')
        @($R.Run.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-a') -Because 'the -Resume run must collect sub-a again'
        ($R.Post.Text -join "`n") | Should -Match 'verification: OK \(2 zip\(s\) match 1 successful sub\(s\) this run \+ 1 carried'
    }

    It 'one-subscription fallback: a run that leaves no zip for sub-a clears its record, and the next -Resume collects it again' {
        $Global:RdaCarryTestNoZipIds = @('sub-a')
        $S = script:Read-State -Path $script:State
        $null = & $script:FallbackBlock $script:FailRoot @($script:A) $S.Completed @() $S.Reports $script:Root $script:State 't' 6>$null
        $After2 = script:Read-State -Path $script:State
        $R = script:Invoke-ResumeRun -Root $script:Root -State $script:State

        $After2.Completed | Should -BeNullOrEmpty -Because 'the latest run of sub-a left no report'
        $After2.Reports | Should -BeNullOrEmpty
        $After2.Failed | Should -BeNullOrEmpty
        @($R.Run.SkippedSubscriptions | ForEach-Object Id) | Should -BeNullOrEmpty -Because 'the -Resume run must not skip a subscription whose latest run left no report'
        @($R.Run.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-a', 'sub-b')
    }
}

Describe 'The -Resume output shows when each carried report was written' {
    BeforeEach {
        $script:Root = script:New-CaseRoot
        $script:Zip = script:New-TestReport -Root $script:Root -Stamp '5aaaa' -SubName 'Sub A'
    }

    It 'shows the date of a carried report written <Label>, and its age as <Days> day(s)' -TestCases @(
        @{ Label = '400 days ago'; Offset = -400; Days = 400 },
        @{ Label = 'in the future (clock skew)'; Offset = 3; Days = 0 }
    ) {
        script:Set-ReportAge -Zip $script:Zip -When (Get-Date).ToUniversalTime().AddDays($Offset).AddMinutes(-5)
        $Rec = New-CompletedReportRecord -InventoryRoot $script:Root -Id 'sub-a' -Name 'Sub A' -ZipPath $script:Zip -Obfuscated $false
        $Post = script:Invoke-Post -Root $script:Root -Since (Get-Date) -ThisRun @() -Skipped @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' }) -Reports @($Rec)
        $Expected = '  - Sub A: report written {0}, {1} day(s) ago' -f (Get-Item -LiteralPath $script:Zip).LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $Days
        @($Post.Text | Where-Object { $_ -like '  - Sub A: *' }) | Should -Be @($Expected)
        ($Post.Text -join "`n") | Should -Match 'verification: OK \(1 zip\(s\) match 0 successful sub\(s\) this run \+ 1 carried'
    }
}

Describe 'A -Resume run on a state file written before CompletedReports existed' {
    BeforeAll {
        # The resume-state loading at startup, from reading the state file through
        # the "Resume mode" lines, lifted from the wrapper's AST and run as written.
        $Tokens = $null
        $ParseErrors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$Tokens, [ref]$ParseErrors)
        $Top = @($Ast.EndBlock.Statements)
        $From = -1
        $To = -1
        for ($i = 0; $i -lt $Top.Count; $i++)
        {
            if ($From -lt 0 -and $Top[$i] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $Top[$i].Left.Extent.Text -eq '$CompletedIds') { $From = $i }
            if ($From -ge 0 -and $Top[$i] -is [System.Management.Automation.Language.IfStatementAst] -and $Top[$i].Clauses[0].Item1.Extent.Text -eq '$Resume') { $To = $i; break }
        }
        if ($From -lt 0 -or $To -lt 0) { throw 'Expected the resume-state loading at startup in the wrapper.' }
        $StartText = (@($Top[$From..$To] | ForEach-Object { $_.Extent.Text }) -join "`n")
        $script:StartupBlock = [scriptblock]::Create(
            "param(`$InventoryRoot, `$TenantID, `$ResumeStateFile, `$Resume)`n`$ResumeFailedOnly = `$false`n" +
            $StartText + "`n[pscustomobject]@{ CompletedIds = @(`$CompletedIds); FailedAttempts = @(`$FailedAttempts); CompletedReports = @(`$CompletedReports) }")

        # Startup, then the sequential loop over sub-a and sub-b, then the post-processing.
        function script:Invoke-ResumeFromState
        {
            param($Root, $State)
            $Start = @(& $script:StartupBlock $Root 't' $State $true 6>&1)
            $Loaded = $Start | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['CompletedIds'] } | Select-Object -Last 1
            $StartText = @($Start | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            $Since = Get-Date
            $Run = & $script:SequentialBlock $script:FakeRoot @($script:A, $script:B) $true @($Loaded.CompletedIds) @($Loaded.FailedAttempts) @($Loaded.CompletedReports) $Root $State 't' $false 6>$null
            $Post = script:Invoke-Post -Root $Root -Since $Since -ThisRun $Run.SubResourceCounts -Skipped $Run.SkippedSubscriptions -Reports $Run.CompletedReports
            return [pscustomobject]@{ Loaded = $Loaded; StartText = $StartText; Run = $Run; Post = $Post }
        }
    }

    BeforeEach {
        $script:Root = script:New-CaseRoot
        $Global:RdaCarryTestRoot = $script:Root
        $global:LASTEXITCODE = 0
        $script:State = Join-Path $script:Root '.resume-state-t.json'
        $script:A = [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' }
        $script:B = [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B' }
        # An older version completed sub-a (its zip is on disk, two hours old) and
        # recorded a failed attempt at sub-c, without a CompletedReports key.
        $OldZip = script:New-TestReport -Root $script:Root -Stamp '1aaaa' -SubName 'Sub A'
        script:Set-ReportAge -Zip $OldZip -When (Get-Date).AddHours(-2)
        [ordered]@{
            TenantID                 = 't'
            CompletedSubscriptionIds = @('sub-a')
            FailedAttempts           = @([ordered]@{ Id = 'sub-c'; Name = 'Sub C'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'stand-in'; Attempts = 1 })
            LastUpdated              = '2026-01-01T00:00:00Z'
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:State -Encoding utf8
    }

    It 'collects the subscriptions it lists as completed again, says so in one line, and ships a report for each' {
        $R = script:Invoke-ResumeFromState -Root $script:Root -State $script:State

        @($R.Run.SkippedSubscriptions | ForEach-Object Id) | Should -BeNullOrEmpty -Because 'no report of sub-a is recorded, so skipping it would leave it out of the bundle'
        @($R.Run.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-a', 'sub-b')
        @($R.StartText | Where-Object { $_ -like 'Resume mode:*' }) | Should -Be @('Resume mode: the resume state was written by an older version, so 1 subscription(s) will be collected again for the bundle to hold their reports.')
        @($R.Post.Result.Uncarried).Count | Should -Be 0
        ($R.Post.Text -join "`n") | Should -Match 'verification: OK \(2 zip\(s\) match 2 successful sub\(s\)\)'
        @(script:Get-InnerZipNames -OuterZip $R.Post.Result.OuterZipFile).Count | Should -Be 2
        @($R.Loaded.FailedAttempts | ForEach-Object Id) | Should -Be @('sub-c') -Because 'failed attempts are read as before'
        @(Get-FailedAttempts -Path $script:State -Tenant 't' | ForEach-Object Id) | Should -Be @('sub-c')
    }

    It 'counts only what the state file lists, not the per-stream state an interrupted parallel run left' {
        # Two ids in the state file (the fold joins a one-id list and the stranded ids
        # into one string), and an older version's stream file: sub-x completed, no
        # Reports. The stream that owns it skips sub-x on -Resume, so it is not one this
        # run collects again.
        [ordered]@{ TenantID = 't'; CompletedSubscriptionIds = @('sub-a', 'sub-b'); FailedAttempts = @(); LastUpdated = '2026-01-01T00:00:00Z' } | ConvertTo-Json | Set-Content -LiteralPath $script:State -Encoding utf8
        @{ Tenant = 't'; StreamId = '0'; Completed = @('sub-x'); FailedAttempts = @() } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        $Start = @(& $script:StartupBlock $script:Root 't' $script:State $true 6>&1)
        $Loaded = $Start | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['CompletedIds'] } | Select-Object -Last 1
        $Lines = @($Start | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData } | Where-Object { $_ -like 'Resume mode:*' })

        $Lines | Should -Be @(
            'Resume mode: the resume state was written by an older version, so 2 subscription(s) will be collected again for the bundle to hold their reports.',
            'Resume mode: 1 previously completed subscription(s) will be skipped.')
        @($Loaded.CompletedIds) | Should -Be @('sub-x')
    }

    It 'the next -Resume run skips them as usual and carries the reports this run recorded' {
        $null = script:Invoke-ResumeFromState -Root $script:Root -State $script:State
        Get-ChildItem -LiteralPath $script:Root -Directory -Filter 'ResourcesReport*' | ForEach-Object {
            $Zip = Get-ChildItem -LiteralPath $_.FullName -Filter '*.zip' | Select-Object -First 1
            if ($Zip) { script:Set-ReportAge -Zip $Zip.FullName -When (Get-Date).AddHours(-1) }
        }
        $R3 = script:Invoke-ResumeFromState -Root $script:Root -State $script:State

        @($R3.StartText | Where-Object { $_ -like 'Resume mode:*' }) | Should -Be @('Resume mode: 2 previously completed subscription(s) will be skipped.')
        @($R3.Run.SkippedSubscriptions | ForEach-Object Id) | Should -Be @('sub-a', 'sub-b')
        @($R3.Post.Result.Uncarried).Count | Should -Be 0
        ($R3.Post.Text -join "`n") | Should -Match 'verification: OK \(2 zip\(s\) match 0 successful sub\(s\) this run \+ 2 carried'
    }
}
