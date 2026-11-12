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
        "function Exit-Wrapper { param([int]`$Code) throw ('Exit-Wrapper ' + `$Code) }`n" +
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
    # From the loop's list initializers on, so the lifted block starts them as the wrapper does.
    for ($i = $AggStart - 1; $i -ge 0 -and $Body[$i].Extent.Text -match '^\$Stream\w+ = @\(\)$'; $i--) { $AggStart = $i }
    if ($Body[$AggStart].Extent.Text -notmatch '^\$Stream\w+ = @\(\)$') { throw 'Expected the list initializers before the stream-summary loop.' }
    $AggText = (@($Body[$AggStart..($Body.Count - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n")
    $script:AggregateBlock = [scriptblock]::Create(
        "param(`$StreamSummaries, `$InventoryRoot, `$TenantID, `$ResumeStateFile, `$CompletedIds, `$FailedAttempts, `$CompletedReports)`n" +
        "`$SkippedSubscriptions = @(); `$SubResourceCounts = @(); `$FailedSubscriptions = @(); `$DiagFile = `$null; `$RunStartTime = (Get-Date).AddMinutes(-1); `$StreamRunId = 'run-1'`n" +
        $AggText + "`n[pscustomobject]@{ SkippedSubscriptions = @(`$SkippedSubscriptions); SubResourceCounts = @(`$SubResourceCounts); CompletedIds = @(`$CompletedIds); CompletedReports = @(`$CompletedReports); FailedSubscriptions = @(`$FailedSubscriptions); UnreadableStreamFiles = @(`$UnreadableStreamFiles); ResumeStateSaveFailed = [bool]`$script:ResumeStateSaveFailed }")

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
    # The snapshot of the reports already there when a run starts, as written.
    $script:PreRunText = (@($Top | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -in '$PreRunReportDirs', '$PreRunZips' } | ForEach-Object { $_.Extent.Text }) -join "`n")
    $script:PostText = $PostText
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
        $Src | Should -Match ([regex]::Escape('Get-WrapperExitCode -AuthSkipped $AuthSkipped -CollectorsFailed $CollectorsFailed -ReportsMissing (($ResumeStateSaveFailed -and -not $RunClean) -or (@($UncarriedSkipped).Count -gt 0) -or (@($RetryLimitedOwed).Count -gt 0) -or (@($UnreadableStreamFiles).Count -gt 0) -or (@($LeftStreamFiles).Count -gt 0) -or (@($RetryOwedNotInRun).Count -gt 0)) -SubscriptionsFailed (@($FailedSubscriptions | Where-Object { $null -ne $_ }).Count -gt 0)'))
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

Describe 'The bundle never takes a report that was there before the run started' {
    It 'leaves out an older report dated after the run''s start (a clock moved back), so a subscription collected again is in it once' {
        @($script:PreRunText -split "`n").Count | Should -Be 2
        $Root = script:New-CaseRoot
        $Old = script:New-TestReport -Root $Root -Stamp '1old' -SubName 'Sub A'
        script:Set-ReportAge -Zip $Old -When (Get-Date).AddHours(2)
        $Since = Get-Date
        $Block = [scriptblock]::Create("param(`$RealScriptRoot, `$InventoryRoot, `$RunStartTime, `$SubResourceCounts, `$SkippedSubscriptions, `$CompletedReports, `$Resume, `$Obfuscate, `$ResumeStateFile, `$TenantID)`n" +
            "function Exit-Wrapper { param([int]`$Code) throw ('Exit-Wrapper ' + `$Code) }`n" + $script:PreRunText + "`n" +
            "`$null = script:New-TestReport -Root `$InventoryRoot -Stamp '2new' -SubName 'Sub A'`n" +
            "`$WrapperTranscriptStarted = `$false; `$FailedSubscriptions = @(); `$Detailed = `$false`n" + $script:PostText + "`n[pscustomobject]@{ OuterZipFile = `$OuterZipFile }")
        $Out = @(& $Block $script:RepoRoot $Root $Since @([pscustomobject]@{ Name = 'Sub A'; Id = 'sub-a'; Count = 2 }) @() @() $true $false (Join-Path $Root '.resume-state-t.json') 't' 6>$null)
        $Result = $Out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['OuterZipFile'] } | Select-Object -Last 1
        @(script:Get-InnerZipNames -OuterZip $Result.OuterZipFile) | Should -Be @('ResourcesReport_2new.zip')
    }

    It 'MainSummary leaves out a report folder that was there before the run started, whatever its time' {
        $Root = script:New-CaseRoot
        $Old = script:New-TestReport -Root $Root -Stamp '1old' -SubName 'Sub Old'
        script:Set-ReportAge -Zip $Old -When (Get-Date).AddHours(2)
        $null = script:New-TestReport -Root $Root -Stamp '2new' -SubName 'Sub New'
        $Html = Join-Path $Root 'MainSummary.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $Root -HtmlFile $Html -SinceTime (Get-Date).AddMinutes(-5) -ExcludeFolders @(Split-Path -Path $Old -Parent) -TenantId 't' -Version 'test' -PlatOS 'test'
        $Text = Get-Content -LiteralPath $Html -Raw
        $Text | Should -Match 'Sub New'
        $Text | Should -Not -Match 'Sub Old'
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
            param($Root, [string[]]$Ids, [string[]]$Names, [switch]$Resume, [string]$RunId = 'run-1')
            $WorkerArgs = @{
                RunId              = $RunId
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

    It 'a cut-off run''s completion is collected again (fail-safe rule), and the bundle holds one copy of every subscription' {
        $Root = script:New-CaseRoot
        $Global:RdaCarryTestRoot = $Root
        $State = Join-Path $Root '.resume-state-t.json'

        # Earlier run: stream 0 completed sub-a, then the parent was cut off
        # before its merge, so that run never proved the result saved.
        $null = script:Invoke-Worker -Root $Root -Ids @('sub-a') -Names @('Sub A') -RunId 'run-0'
        $StreamFile = Join-Path $Root '.resume-state-t-stream-0.json'
        $Run1Reports = @((Get-Content -LiteralPath $StreamFile -Raw | ConvertFrom-Json).Reports | Where-Object { $null -ne $_ } | ForEach-Object Id)
        Get-ChildItem -LiteralPath $Root -Directory -Filter 'ResourcesReport*' | ForEach-Object {
            script:Set-ReportAge -Zip (Get-ChildItem -LiteralPath $_.FullName -Filter '*.zip' | Select-Object -First 1).FullName -When (Get-Date).AddHours(-2)
        }
        Remove-Item -LiteralPath (Join-Path $Root '.rda-stream-0-summary.json') -Force

        # -Resume: the parent folds the stranded stream state, as written.
        $Folded = & $script:FoldBlock $Root 't' $State @() @() @() 6>$null
        Test-Path -LiteralPath $StreamFile | Should -BeFalse -Because 'the fold removed the stream file once the unified file was saved'
        @($Folded.CompletedIds) | Should -BeNullOrEmpty -Because 'a completion of a cut-off run does not count as done'
        @(script:Read-StateReports -Path $State) | Should -BeNullOrEmpty -Because 'no report of the cut-off run is carried'

        # So the stream of this run (run-1) is given sub-a again with sub-b.
        $Since = Get-Date
        $Summary = script:Invoke-Worker -Root $Root -Ids @('sub-a', 'sub-b') -Names @('Sub A', 'Sub B') -Resume
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = (Join-Path $Root '.rda-stream-0-summary.json'); FailuresPath = (Join-Path $Root 'failures-stream-0.log'); SubCount = 2 })
        $Agg = & $script:AggregateBlock $Streams $Root 't' $State @($Folded.CompletedIds) @() @($Folded.CompletedReports) 6>$null
        $Post = script:Invoke-Post -Root $Root -Since $Since -ThisRun $Agg.SubResourceCounts -Skipped @() -Reports $Agg.CompletedReports

        $Inner = @(script:Get-InnerZipNames -OuterZip $Post.Result.OuterZipFile)
        $Inner.Count | Should -Be 2
        @($Inner | Where-Object { $_ -like '*sub-a*' }).Count | Should -Be 1 -Because 'collecting again adds no second copy of sub-a'
        @($Inner | Where-Object { $_ -like '*sub-b*' }).Count | Should -Be 1
        ($Post.Text -join "`n") | Should -Match 'verification: OK \(2 zip\(s\) match 2 successful sub\(s\)\)'
        $Run1Reports | Should -Be @('sub-a') -Because 'the stream records the zip of the subscription it completed'
        @($Summary.Skipped | ForEach-Object Id) | Should -BeNullOrEmpty
        @($Agg.SubResourceCounts | ForEach-Object Id | Sort-Object) | Should -Be @('sub-a', 'sub-b')
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
            "function Exit-Wrapper { param([int]`$Code) throw ('Exit-Wrapper ' + `$Code) }`n" +
            "`$StreamCount = 1; `$Obfuscate = `$false; `$SubResourceCounts = @(); `$FailedSubscriptions = @(); `$DiagFile = `$null; `$InventoryPassthrough = @{ ConcurrencyLimit = 6 }`n" +
            # The parallel path builds the list it slices before this block; these runs are not -Resume runs, so it is every subscription.
            "`$PendingSubscriptions = @(`$Subscriptions)`n" +
            ($OneIf[0].Extent.Text -replace '\$PSScriptRoot', '$FakeScriptRoot'))

        function script:Invoke-FailWorker
        {
            param($Root, [string[]]$Ids, [string[]]$Names)
            $WorkerArgs = @{
                RunId              = 'run-1'
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

    It 'before a sub is collected, one more failed run is saved and its earlier completion taken out; a run that cannot save that stops before collecting it (<Case>)' -ForEach @(
        @{ Case = 'saved'; SaveFails = $false }
        @{ Case = 'the save does not reach the disk'; SaveFails = $true }
    ) {
        (script:Read-State -Path $script:State).Completed | Should -Be @('sub-a')
        # The sequential and one-subscription paths call it before ResourceInventory.ps1.
        $Src = Get-Content -LiteralPath $script:WrapperPath -Raw
        ([regex]::Matches($Src, 'Save-WriteAheadAttempt -Path \$ResumeStateFile')).Count | Should -Be 2
        $S = script:Read-State -Path $script:State
        if ($SaveFails)
        {
            Mock Set-Content -ParameterFilter { [string]$LiteralPath -like '*.resume-state-*.tmp' } -MockWith { throw 'stand-in: disk full' }
            $Before = @(Get-ChildItem -LiteralPath $script:Root -Directory -Filter 'ResourcesReport*').Count
            { & $script:SeqBlock $script:FailRoot @($script:A) $false $S.Completed @() $S.Reports $script:Root $script:State 't' $false 6>$null } | Should -Throw 'Exit-Wrapper 2'
            @(Get-ChildItem -LiteralPath $script:Root -Directory -Filter 'ResourcesReport*').Count | Should -Be $Before -Because 'sub-a was not collected'
            (script:Read-State -Path $script:State).Completed | Should -Be @('sub-a') -Because 'nothing was collected, so the old state still holds'
        }
        else
        {
            $W = Save-WriteAheadAttempt -Path $script:State -Tenant 't' -Id 'sub-a' -Name 'Sub A' -CompletedIds $S.Completed -FailedAttempts @() -Reports $S.Reports
            $W.Saved | Should -BeTrue
            $After = script:Read-State -Path $script:State
            $After.Completed | Should -BeNullOrEmpty -Because 'a cut-off from here on leaves no older completion of sub-a for a -Resume to skip on'
            $After.Reports | Should -BeNullOrEmpty
            $E = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object Id -eq 'sub-a')
            [int]$E[0].Attempts | Should -Be 1 -Because 'a cut-off from here on still counts this run'
        }
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

    It 'a stream that did not start leaves its subs not done: an earlier completion goes and each counts this run once' {
        $S = script:Read-State -Path $script:State
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'failed-to-start'; Reason = 'stand-in'; Completed = @(); ResourceCounts = @()
            Failed = @(@{ Id = 'sub-a'; Name = 'Sub A'; Reason = 'stream did not start: Az context import failed' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 1 })
        $Agg = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed @() $S.Reports 6>$null

        @($Agg.CompletedIds) | Should -BeNullOrEmpty -Because 'this run gave sub-a to a stream and nothing proves it done'
        @($Agg.CompletedReports) | Should -BeNullOrEmpty
        [int](@(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object Id -eq 'sub-a')[0].Attempts) | Should -Be 1
        @($Agg.FailedSubscriptions).Count | Should -Be 1
    }

    It 'a stream that did not start counts one more failed run for each sub it leaves not done, once, so the retry limit ends a stream that never starts' {
        $S = script:Read-State -Path $script:State
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 2 })
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'failed-to-start'; Reason = 'stand-in'; Completed = @(); ResourceCounts = @()
            Failed = @(@{ Id = 'sub-a'; Name = 'Sub A'; Reason = 'stream did not start' }, @{ Id = 'sub-b'; Name = 'Sub B'; Reason = 'stream did not start' }, @{ Id = 'sub-b'; Name = 'Sub B'; Reason = 'stream did not start' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 2 })
        $Agg = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null
        @($Agg.CompletedIds) | Should -BeNullOrEmpty
        $After = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ } | Sort-Object Id)
        @($After | ForEach-Object Id) | Should -Be @('sub-a', 'sub-b')
        [int]$After[1].Attempts | Should -Be 3 -Because 'listed twice, it is still one failed run'
        @(Get-RetryLimitedAttempts -FailedAttempts $After | ForEach-Object Id) | Should -Be @('sub-b')
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
        $After2.Failed | Should -Be @('sub-a') -Because 'a run that left no zip is one more failed run, so the retry limit ends a sub that keeps leaving none'
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
        $After2.Failed | Should -Be @('sub-a') -Because 'one more failed run'
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
        $After2.Failed | Should -Be @('sub-a') -Because 'one more failed run'
        @($R.Run.SkippedSubscriptions | ForEach-Object Id) | Should -BeNullOrEmpty -Because 'the -Resume run must not skip a subscription whose latest run left no report'
        @($R.Run.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-a', 'sub-b')
    }

    It 'a subscription the stream''s summary lists as failed counts one more failed run when its saved file holds only the parent''s entry' {
        $S = script:Read-State -Path $script:State
        # Slice [A, B]; B on the retry list at 2. The stream completed A and saved its
        # file (with B's entry as the parent gave it); its save of B's failure did not
        # reach the disk, and its summary lists B as failed.
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 2 })
        [pscustomobject]@{ RunId = 'run-1'; Tenant = 't'; StreamId = '0'; Completed = @('sub-a'); FailedAttempts = $Prior; Reports = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'partial-failure'; Completed = @('sub-a'); ResourceCounts = @(); Failed = @(@{ Id = 'sub-b'; Name = 'Sub B'; Reason = 'stand-in' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 2 })
        $null = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null
        $After = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ })
        [int](@($After | Where-Object Id -eq 'sub-b')[0].Attempts) | Should -Be 3 -Because 'the summary says this run failed it'
    }

    It 'a subscription the stream''s summary lists as failed is not counted again when its saved file recorded this run''s failure' {
        $S = script:Read-State -Path $script:State
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 2 })
        $Saved = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = (Get-Date).ToUniversalTime().ToString('o'); Reason = 'stand-in'; Attempts = 3 })
        [pscustomobject]@{ RunId = 'run-1'; Tenant = 't'; StreamId = '0'; Completed = @(); FailedAttempts = $Saved; Reports = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'partial-failure'; Completed = @(); ResourceCounts = @(); Failed = @(@{ Id = 'sub-b'; Name = 'Sub B'; Reason = 'stand-in' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 1 })
        $null = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null
        $After = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ })
        [int](@($After | Where-Object Id -eq 'sub-b')[0].Attempts) | Should -Be 3 -Because 'the file already counted this run''s failure'
    }

    It 'parallel: a retried subscription a stream completed but could not save keeps its write-ahead count, one it could not count is not collected, and the next -Resume collects both once and owes nothing' {
        # The unified state: sub-a completed (BeforeEach); sub-b and sub-c on the retry list.
        $C = [pscustomobject]@{ Id = 'sub-c'; Name = 'Sub C' }
        $S = script:Read-State -Path $script:State
        $Prior = @(
            [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 1 },
            [pscustomobject]@{ Id = 'sub-c'; Name = 'Sub C'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 1 })
        Save-CompletedSubscriptionIds -Path $script:State -Tenant 't' -Ids $S.Completed -FailedAttempts $Prior -Reports $S.Reports
        # Run 2, -ResumeFailedOnly: the stream saves sub-b's write-ahead count and
        # completes it, and from then on no save of its own state file reaches
        # the disk: sub-b's result is not saved, and sub-c's write-ahead count
        # cannot be saved, so sub-c is not collected.
        $Global:RdaCarryTestFailIds = @('sub-c')
        $Global:RdaStreamSaves = 0
        Mock Set-Content -ParameterFilter { [string]$LiteralPath -like '*.resume-state-t-stream-*.json.tmp' -and (++$Global:RdaStreamSaves) -gt 1 } -MockWith { throw 'stand-in: disk full' }
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        $WorkerArgs = @{
            RunId = 'run-1'
            TenantID = 't'; StreamId = '0'; InventoryRoot = $script:Root; ScriptRoot = $script:FailRoot
            AzContextPath = (Join-Path $script:Root 'ctx.json'); StreamSummaryPath = $Summary; StreamFailuresPath = (Join-Path $script:Root 'failures-stream-0.log')
            SubscriptionIds = @('sub-b', 'sub-c'); SubscriptionNames = @('Sub B', 'Sub C'); PriorFailedAttempts = $Prior; ResumeFailedOnly = $true; ConcurrencyLimit = 6
        }
        & (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1') @WorkerArgs 6>$null
        @((Get-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Raw | ConvertFrom-Json).Completed) | Should -BeNullOrEmpty -Because 'the stream could not save sub-b''s result'
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 2 })
        $Agg = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null
        $After2 = script:Read-State -Path $script:State
        # sub-b's result was not saved, so it is not done: its write-ahead count
        # stands. sub-c was not collected, so nothing is counted for it. Both named.
        @($After2.Failed | Sort-Object) | Should -Be @('sub-b', 'sub-c')
        @($After2.Completed) | Should -Be @('sub-a')
        @($After2.Reports | ForEach-Object Id) | Should -Be @('sub-a') -Because 'no report of sub-b is recorded, so none can be carried twice'
        [int](@(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object Id -eq 'sub-b')[0].Attempts) | Should -Be 2
        [int](@(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object Id -eq 'sub-c')[0].Attempts) | Should -Be 1
        @($Agg.FailedSubscriptions | Where-Object { $_ -like 'Sub B (stream-0: its stream could not save its result, so it is collected again)' }).Count | Should -Be 1
        @($Agg.FailedSubscriptions | Where-Object { $_ -like 'Sub C (stream-0: its stream could not save its state before collecting it*' }).Count | Should -Be 1
        Remove-Variable -Name RdaStreamSaves -Scope Global -ErrorAction SilentlyContinue

        # Run 3, -Resume: sub-a is skipped and carried; sub-b and sub-c are
        # collected. The sequential block stands in for the parallel -Resume
        # pre-filter, which skips and carries by the same lists.
        $Global:RdaCarryTestFailIds = @()
        $Since = Get-Date
        $S = script:Read-State -Path $script:State
        $Run = & $script:SeqBlock $script:FailRoot @($script:A, $script:B, $C) $true $S.Completed @(Get-FailedAttempts -Path $script:State -Tenant 't') $S.Reports $script:Root $script:State 't' $false 6>$null
        $Post = script:Invoke-Post -Root $script:Root -Since $Since -ThisRun $Run.SubResourceCounts -Skipped $Run.SkippedSubscriptions -Reports $Run.CompletedReports
        @($Run.SkippedSubscriptions | ForEach-Object Id) | Should -Be @('sub-a')
        @($Run.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-b', 'sub-c')
        @($Post.Result.Uncarried).Count | Should -Be 0
        $Inner = @(script:Get-InnerZipNames -OuterZip $Post.Result.OuterZipFile)
        $Inner.Count | Should -Be 3 -Because 'one zip per subscription: sub-a carried, sub-b and sub-c of this run'
        @($Inner | Where-Object { $_ -like '*Sub B*' -or $_ -like '*sub-b*' }).Count | Should -Be 1 -Because 'collecting sub-b again adds no second copy'
        $After3 = script:Read-State -Path $script:State
        $After3.Failed | Should -BeNullOrEmpty -Because 'the retry list is empty after run 3'
        @($After3.Completed | Sort-Object) | Should -Be @('sub-a', 'sub-b', 'sub-c')

        # Nothing is owed after run 3, so the wrapper's clean-run rule removes
        # the resume state (that block is not run here) and the next run starts
        # afresh: nothing keeps sub-b in a loop.
        @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ }).Count | Should -Be 0
    }

    It 'parallel: a subscription whose stream never saves its result reaches the retry limit, so the retries end with it named' {
        $S = script:Read-State -Path $script:State
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 2 })
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'ok'; Completed = @('sub-b'); ResourceCounts = @(); Failed = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 1 })
        $null = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null
        $Limited = @(Get-RetryLimitedAttempts -FailedAttempts @(Get-FailedAttempts -Path $script:State -Tenant 't'))
        @($Limited | ForEach-Object Id) | Should -Be @('sub-b') -Because 'the third run that cannot save it ends the cycle'
        $Said = @(& { Write-RetryLimitSummary -RetryLimited $Limited -TenantID 't' } 6>&1 | ForEach-Object { [string]$_ })
        @($Said | Where-Object { $_ -like 'Retry Limit Reached:*1 (Sub B)*-Resume and -ResumeFailedOnly do not collect these*' }).Count | Should -Be 1
    }

    It 'parallel: a summary of another run, tenant or stream is not used at all (<Case>)' -ForEach @(
        @{ Case = 'another run'; RunId = 'run-0'; Tenant = 't'; StreamId = '0' }
        @{ Case = 'another tenant'; RunId = 'run-1'; Tenant = 'other'; StreamId = '0' }
        @{ Case = 'another stream'; RunId = 'run-1'; Tenant = 't'; StreamId = '1' }
    ) {
        $S = script:Read-State -Path $script:State
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 1 })
        $Zip = Join-Path $script:Root 'sub-b-report.zip'
        Set-Content -LiteralPath $Zip -Value 'zip'
        $Record = New-CompletedReportRecord -InventoryRoot $script:Root -Id 'sub-b' -Name 'Sub B' -ZipPath $Zip -Obfuscated $false
        $Record | Should -Not -BeNullOrEmpty
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        # It also lists sub-a (completed) as failed and as left without a zip.
        @{ RunId = $RunId; StreamId = $StreamId; Tenant = $Tenant; Status = 'partial-failure'; Completed = @('sub-b'); ResourceCounts = @(); Failed = @(@{ Id = 'sub-a'; Name = 'Sub A'; Reason = 'other run' }); NoReport = @(@{ Id = 'sub-a'; Name = 'Sub A' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 1 })
        $Agg = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null
        @($Agg.CompletedIds) | Should -Be @('sub-a') -Because "a summary for $Case is not this stream's: its failure of sub-a is not used either"
        @(Get-FailedAttempts -Path $script:State -Tenant 't' | ForEach-Object { [string]$_.Id }) | Should -Not -Contain 'sub-a'
        @($Agg.FailedSubscriptions) | Should -Contain "stream-0 (summary not this run's)"
    }

    It 'parallel: a completion only the summary names ends no retry, and counts one more failed run (fail-safe rule)' {
        $S = script:Read-State -Path $script:State
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 1 })
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'ok'; Completed = @('sub-b', 'sub-c', 'sub-c'); ResourceCounts = @(); Failed = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 2 })
        $Agg = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null
        @($Agg.CompletedIds) | Should -Be @('sub-a')
        @($Agg.CompletedReports | ForEach-Object { [string]$_.Id }) | Should -Be @('sub-a')
        $After = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ })
        [int](@($After | Where-Object Id -eq 'sub-b')[0].Attempts) | Should -Be 2
        [int](@($After | Where-Object Id -eq 'sub-c')[0].Attempts) | Should -Be 1 -Because 'listed twice, it is still one failed run'
        @($Agg.FailedSubscriptions | Where-Object { $_ -like '*its stream could not save its result, so it is collected again*' }).Count | Should -Be 2
    }

    It 'parallel: a stream keeps the write-ahead count of a sub it completed until the merge, so a parent cut off first leaves it counted and its earlier completion goes' {
        # sub-a completed by an earlier run (BeforeEach); sub-b on the retry list at 1.
        $S = script:Read-State -Path $script:State
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 1 })
        Save-CompletedSubscriptionIds -Path $script:State -Tenant 't' -Ids $S.Completed -FailedAttempts $Prior -Reports $S.Reports
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        $WorkerArgs = @{
            RunId = 'run-1'
            TenantID = 't'; StreamId = '0'; InventoryRoot = $script:Root; ScriptRoot = $script:FailRoot
            AzContextPath = (Join-Path $script:Root 'ctx.json'); StreamSummaryPath = $Summary; StreamFailuresPath = (Join-Path $script:Root 'failures-stream-0.log')
            SubscriptionIds = @('sub-a', 'sub-b'); SubscriptionNames = @('Sub A', 'Sub B'); PriorFailedAttempts = $Prior; ConcurrencyLimit = 6
        }
        & (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1') @WorkerArgs 6>$null
        $File = Get-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Raw | ConvertFrom-Json
        @($File.Completed | Sort-Object) | Should -Be @('sub-a', 'sub-b')
        @($File.FailedAttempts | ForEach-Object Id | Sort-Object) | Should -Be @('sub-a', 'sub-b') -Because 'the counts stay until the merge proves the results saved'
        # The parent is cut off before its merge; the next -Resume start folds the file in.
        $Folded = & $script:FoldBlock $script:Root 't' $script:State @($S.Completed) @($Prior) @($S.Reports) 6>$null
        @($Folded.CompletedIds) | Should -Not -Contain 'sub-a' -Because 'the earlier completion is not used: this run started sub-a again'
        $After = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ })
        [int](@($After | Where-Object Id -eq 'sub-a')[0].Attempts) | Should -Be 1
        [int](@($After | Where-Object Id -eq 'sub-b')[0].Attempts) | Should -Be 2 -Because 'the cut-off run counts'
    }

    It 'parallel: a sub whose write-ahead count a stream cannot save leaves the file as it was for that sub' {
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        # The first save of the stream file (sub-a's count) does not reach the disk; later ones do.
        $Global:RdaStreamSaves = 0
        Mock Set-Content -ParameterFilter { [string]$LiteralPath -like '*.resume-state-t-stream-*.json.tmp' -and (++$Global:RdaStreamSaves) -eq 1 } -MockWith { throw 'stand-in: disk full' }
        $WorkerArgs = @{
            RunId = 'run-1'
            TenantID = 't'; StreamId = '0'; InventoryRoot = $script:Root; ScriptRoot = $script:FailRoot
            AzContextPath = (Join-Path $script:Root 'ctx.json'); StreamSummaryPath = $Summary; StreamFailuresPath = (Join-Path $script:Root 'failures-stream-0.log')
            SubscriptionIds = @('sub-a', 'sub-b'); SubscriptionNames = @('Sub A', 'Sub B'); ConcurrencyLimit = 6
        }
        & (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1') @WorkerArgs 6>$null
        Remove-Variable -Name RdaStreamSaves -Scope Global -ErrorAction SilentlyContinue
        $Sum = Get-Content -LiteralPath $Summary -Raw | ConvertFrom-Json
        @($Sum.NotAttempted | ForEach-Object Id) | Should -Be @('sub-a')
        $File = Get-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Raw | ConvertFrom-Json
        @($File.FailedAttempts | ForEach-Object Id) | Should -Not -Contain 'sub-a' -Because 'it was not collected, so nothing about it is counted'
        @($File.Completed) | Should -Be @('sub-b')
    }

    It 'a stream does not list a sub as both completed and failed when a sub its own state file held as completed fails' {
        # Guards the catch-block rule only: the stream's own file lists sub-b as
        # completed (a case the start-up fold prevents today) and this
        # -ResumeFailedOnly run is given sub-b again and it fails.
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 1 })
        $StreamFile = Join-Path $script:Root '.resume-state-t-stream-0.json'
        # Of this run, so the stream reads it.
        @{ RunId = 'run-1'; Tenant = 't'; StreamId = '0'; Completed = @('sub-b'); FailedAttempts = @($Prior); Reports = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StreamFile -Encoding utf8
        $Global:RdaCarryTestFailIds = @('sub-b')
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        $WorkerArgs = @{
            RunId = 'run-1'
            TenantID = 't'; StreamId = '0'; InventoryRoot = $script:Root; ScriptRoot = $script:FailRoot
            AzContextPath = (Join-Path $script:Root 'ctx.json'); StreamSummaryPath = $Summary; StreamFailuresPath = (Join-Path $script:Root 'failures-stream-0.log')
            SubscriptionIds = @('sub-b'); SubscriptionNames = @('Sub B'); PriorFailedAttempts = $Prior; ResumeFailedOnly = $true; ConcurrencyLimit = 6
        }
        & (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1') @WorkerArgs 6>$null
        $Sum = Get-Content -LiteralPath $Summary -Raw | ConvertFrom-Json
        @($Sum.Failed | ForEach-Object Id) | Should -Contain 'sub-b'
        @($Sum.Completed) | Should -Not -Contain 'sub-b'
        $File = Get-Content -LiteralPath $StreamFile -Raw | ConvertFrom-Json
        $File.RunId | Should -Be 'run-1'
        @($File.Completed) | Should -Not -Contain 'sub-b'
        # The stream read its file: sub-b's earlier entry counts one more failed run.
        [int](@($File.FailedAttempts | Where-Object Id -eq 'sub-b')[0].Attempts) | Should -Be 2
    }

    It 'parallel: a per-stream state file of another run, or one of this run without a report record, gives no completion, and its failures are kept (<Case>)' -ForEach @(
        @{ Case = 'another run'; FileRunId = 'run-0'; WithReport = $true }
        @{ Case = 'no report record'; FileRunId = 'run-1'; WithReport = $false }
    ) {
        $S = script:Read-State -Path $script:State
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 1 })
        $Zip = Join-Path $script:Root 'sub-b-report.zip'
        Set-Content -LiteralPath $Zip -Value 'zip'
        $Record = New-CompletedReportRecord -InventoryRoot $script:Root -Id 'sub-b' -Name 'Sub B' -ZipPath $Zip -Obfuscated $false
        $File = Join-Path $script:Root '.resume-state-t-stream-0.json'
        @{ RunId = $FileRunId; Tenant = 't'; StreamId = '0'; Completed = @('sub-b'); FailedAttempts = @(@{ Id = 'sub-y'; Name = 'Sub Y'; LastFailedAt = (Get-Date).ToUniversalTime().ToString('o'); Reason = 'file failure'; Attempts = 1 }); Reports = @(if ($WithReport) { $Record }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $File -Encoding utf8
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'ok'; Completed = @(); ResourceCounts = @(); Failed = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 1 })
        $Agg = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null
        @($Agg.CompletedIds) | Should -Not -Contain 'sub-b' -Because "a file for $Case gives no completion"
        @($Agg.CompletedReports | ForEach-Object { [string]$_.Id }) | Should -Not -Contain 'sub-b'
        @(Get-FailedAttempts -Path $script:State -Tenant 't' | ForEach-Object { [string]$_.Id } | Sort-Object) | Should -Be @('sub-b', 'sub-y') -Because 'sub-b stays on the retry list and the file''s failure is not lost'
        Test-Path -LiteralPath $File | Should -BeFalse -Because 'its records are saved, so it is removed'
    }

    It 'every stream summary and state file carries the run id the parent gave the stream' {
        $Worker = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1') -Raw
        $Wrapper = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $Functions = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1') -Raw
        $Wrapper | Should -Match 'RunId\s+=\s+\$StreamRunId'
        # Each run's summaries are named with its id, and earlier runs' are removed at the start.
        $Wrapper | Should -Match ([regex]::Escape('".rda-stream-{0}-summary-{1}.json" -f $S, $StreamRunId'))
        $Wrapper | Should -Match ([regex]::Escape("-Filter '.rda-stream-*-summary*.json*'"))
        # The no-subscriptions, failed-to-start and full summaries.
        ([regex]::Matches($Worker, 'RunId\s+=\s+\$RunId')).Count | Should -Be 3
        $Functions | Should -Match 'RunId\s+=\s+\$RunId'
        # A worker with an empty slice writes its short summary with the id.
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        $WorkerArgs = @{
            RunId = 'run-1'
            TenantID = 't'; StreamId = '0'; InventoryRoot = $script:Root; ScriptRoot = $script:FailRoot
            AzContextPath = (Join-Path $script:Root 'ctx.json'); StreamSummaryPath = $Summary; StreamFailuresPath = (Join-Path $script:Root 'failures-stream-0.log')
            SubscriptionIds = @(); SubscriptionNames = @(); ConcurrencyLimit = 6
        }
        & (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1') @WorkerArgs 6>$null
        (Get-Content -LiteralPath $Summary -Raw | ConvertFrom-Json).RunId | Should -Be 'run-1'
    }

    It 'parallel: when the resume state cannot be saved, nothing counts as done, the run says so, and the end gives the not-saved note unless a clean run removes the file' {
        $S = script:Read-State -Path $script:State
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 1 })
        $Zip = Join-Path $script:Root 'sub-b-report.zip'
        Set-Content -LiteralPath $Zip -Value 'zip'
        $Record = New-CompletedReportRecord -InventoryRoot $script:Root -Id 'sub-b' -Name 'Sub B' -ZipPath $Zip -Obfuscated $false
        $Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'ok'; Completed = @('sub-b'); ResourceCounts = @(); Failed = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        # The stream saved sub-b with its report in its own file.
        @{ RunId = 'run-1'; Tenant = 't'; StreamId = '0'; Completed = @('sub-b'); FailedAttempts = @(); Reports = @($Record) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 1 })
        # The save does not reach the disk (and says nothing).
        Mock Save-CompletedSubscriptionIds { }
        $script:ResumeStateSaveFailed = $false
        $script:Said = @()
        Mock Write-Host { $script:Said += [string]$Object }
        $Agg = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports
        @($script:Said | Where-Object { $_ -like "WARNING: The resume state file * does not hold every record of this run's per-stream files, so they are kept for the next run: *" }).Count | Should -Be 1
        $Agg.ResumeStateSaveFailed | Should -BeTrue -Because 'the end-of-run note and exit 2 follow from it while the file is there'
        Test-Path -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') | Should -BeTrue -Because 'kept for the next run'
        # The next -Resume start folds in only its failures: sub-b is collected again.
        $Next = & $script:FoldBlock $script:Root 't' $script:State @('sub-a') @() @() 6>$null
        @($Next.CompletedIds) | Should -Not -Contain 'sub-b'
        # The end of the run, as the wrapper has it: with a retry owed the file
        # is put aside and the note is said (exit 2); a clean run (nothing
        # failed or owed) removes it first, and then nothing is said, since
        # nothing is left to skip wrongly.
        $Top = @([System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null).EndBlock.Statements)
        $IsClean = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$RunClean' })
        $Clean = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$RunClean -and (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf)' })
        $Note = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$ResumeStateSaveFailed -and -not $RunClean' })
        $Stays = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$RunClean -and $ResumeStateSaveFailed -and (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf)' })
        $IsClean.Count | Should -Be 1
        $Clean.Count | Should -Be 1
        $Note.Count | Should -Be 1
        $Stays.Count | Should -Be 1
        foreach ($Case in @(@{ Owed = 1; Shown = $true }, @{ Owed = 0; Shown = $false }, @{ Owed = 0; Shown = $true; RemoveFails = $true }))
        {
            Set-Content -LiteralPath $script:State -Value '{}'
            $script:Said = @()
            # A clean run that cannot remove the state it could not save handles it as not saved.
            if ($Case.RemoveFails) { Mock Remove-Item -ParameterFilter { [string]$LiteralPath -eq $script:State } -MockWith { throw 'stand-in: locked' } }
            $End = [scriptblock]::Create("param(`$ResumeStateFile, `$RetryOwedCount)`n`$FailedSubscriptions = @(); `$NotCollected = @(); `$UnreadableStreamFiles = @(); `$LeftStreamFiles = @(); `$ResumeStateSaveFailed = `$true; `$StatePutAside = @()`n" + $IsClean[0].Extent.Text + "`n" + $Clean[0].Extent.Text + "`n" + $Stays[0].Extent.Text + "`n" + $Note[0].Extent.Text + "`n`$script:EndClean = `$RunClean")
            & $End $script:State $Case.Owed
            $script:EndClean | Should -Be (-not $Case.Shown) -Because 'exit 2 follows from a run that is not clean'
            @($script:Said | Where-Object { $_ -like '*FAILED (resume state not saved)*' }).Count | Should -Be $(if ($Case.Shown) { 1 } else { 0 })
            Test-Path -LiteralPath $script:State | Should -BeFalse
            @(Get-ChildItem -LiteralPath $script:Root -Filter '.resume-state-t.json.not-saved-*' -Force).Count | Should -Be $(if ($Case.Shown) { 1 } else { 0 })
            Get-ChildItem -LiteralPath $script:Root -Filter '.resume-state-t.json.not-saved-*' -Force | Remove-Item -Force
        }
        $script:ResumeStateSaveFailed = $false
    }

    It 'parallel: a stream''s failure counts one more run even when the parent''s entry has a later time (a clock moved)' {
        $S = script:Read-State -Path $script:State
        # The parent's entry is dated in the future; this run's stream counted on from it.
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = (Get-Date).AddDays(2).ToUniversalTime().ToString('o'); Reason = 'earlier'; Attempts = 2 })
        $Stream = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = (Get-Date).AddDays(-1).ToUniversalTime().ToString('o'); Reason = 'this run'; Attempts = 3 })
        [pscustomobject]@{ RunId = 'run-1'; Tenant = 't'; StreamId = '0'; Completed = @(); FailedAttempts = $Stream; Reports = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        $Summary = Join-Path $script:Root '.rda-stream-0-summary-run-1.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'partial-failure'; Completed = @(); ResourceCounts = @(); Failed = @(@{ Id = 'sub-b'; Name = 'Sub B'; Reason = 'this run' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 1 })
        $null = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null
        $After = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ })
        [int](@($After | Where-Object Id -eq 'sub-b')[0].Attempts) | Should -Be 3 -Because 'the stream counted this run once, and no more'
        [string](@($After | Where-Object Id -eq 'sub-b')[0].Reason) | Should -Be 'this run'
    }

    It 'parallel: a stream file that holds only the parent''s entry, dated ahead, does not hide this run''s failure from the summary' {
        $S = script:Read-State -Path $script:State
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = (Get-Date).AddDays(2).ToUniversalTime().ToString('o'); Reason = 'earlier'; Attempts = 2 })
        # The stream saved its file with the parent's entry as it was; its save of sub-b's failure did not reach the disk.
        [pscustomobject]@{ RunId = 'run-1'; Tenant = 't'; StreamId = '0'; Completed = @(); FailedAttempts = $Prior; Reports = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        $Summary = Join-Path $script:Root '.rda-stream-0-summary-run-1.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'partial-failure'; Completed = @(); ResourceCounts = @(); Failed = @(@{ Id = 'sub-b'; Name = 'Sub B'; Reason = 'this run' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 1 })
        $null = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null
        $After = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ })
        [int](@($After | Where-Object Id -eq 'sub-b')[0].Attempts) | Should -Be 3 -Because 'the summary says this run failed it once more'
    }

    It 'parallel: every sub of a stream that left no usable summary is not done and counts one more failed run, even one its file of this run lists as completed (<Case>)' -ForEach @(
        @{ Case = 'no summary'; Write = ''; FileDone = $false }
        @{ Case = 'corrupt summary'; Write = '{ cut short'; FileDone = $false }
        @{ Case = 'no summary, file of this run lists sub-b completed with its report'; Write = ''; FileDone = $true }
    ) {
        # sub-a is completed by an earlier run (BeforeEach); sub-b is on the retry list.
        $S = script:Read-State -Path $script:State
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 1 })
        $Summary = Join-Path $script:Root '.rda-stream-0-summary-run-1.json'
        if ($Write) { Set-Content -LiteralPath $Summary -Value $Write }
        if ($FileDone)
        {
            $Zip = Join-Path $script:Root 'sub-b-report.zip'
            Set-Content -LiteralPath $Zip -Value 'zip'
            $Record = New-CompletedReportRecord -InventoryRoot $script:Root -Id 'sub-b' -Name 'Sub B' -ZipPath $Zip -Obfuscated $false
            @{ RunId = 'run-1'; Tenant = 't'; StreamId = '0'; Completed = @('sub-b'); FailedAttempts = @(); Reports = @($Record) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        }
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 2; SubIds = @('sub-a', 'sub-b') })
        $Agg = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null
        @($Agg.CompletedIds) | Should -BeNullOrEmpty -Because 'this run gave sub-a to the stream, and nothing proves its result'
        @($Agg.CompletedReports) | Should -BeNullOrEmpty
        $After = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ })
        [int](@($After | Where-Object Id -eq 'sub-a')[0].Attempts) | Should -Be 1
        [int](@($After | Where-Object Id -eq 'sub-b')[0].Attempts) | Should -Be 2 -Because 'one more failed run, so the retry limit ends it'
        @($Agg.FailedSubscriptions | Where-Object { $_ -like '*its stream ended without a usable summary, so it is collected again*' }).Count | Should -Be 2
    }

    It 'parallel: a failure in another run''s per-stream file does not hide this run''s failure of the same subscription' {
        $S = script:Read-State -Path $script:State
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 1 })
        # A late worker of a cut-off run wrote the file: one more failed run of sub-b.
        $Late = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = (Get-Date).ToUniversalTime().ToString('o'); Reason = 'cut-off run'; Attempts = 2 })
        [pscustomobject]@{ RunId = 'run-0'; Tenant = 't'; StreamId = '0'; Completed = @(); FailedAttempts = $Late; Reports = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        $Summary = Join-Path $script:Root '.rda-stream-0-summary-run-1.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'partial-failure'; Completed = @(); ResourceCounts = @(); Failed = @(@{ Id = 'sub-b'; Name = 'Sub B'; Reason = 'this run' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 1 })
        $null = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null
        $After = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ })
        [int](@($After | Where-Object Id -eq 'sub-b')[0].Attempts) | Should -Be 3 -Because 'the cut-off run and this run are two failed runs'
    }

    It 'parallel: a count that is not a number reads as one failed run, as everywhere, and does not stop the merge' {
        $S = script:Read-State -Path $script:State
        $Prior = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 'many' })
        $Stream = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = (Get-Date).ToUniversalTime().ToString('o'); Reason = 'this run'; Attempts = 2 })
        [pscustomobject]@{ RunId = 'run-1'; Tenant = 't'; StreamId = '0'; Completed = @(); FailedAttempts = $Stream; Reports = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        $Summary = Join-Path $script:Root '.rda-stream-0-summary-run-1.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'partial-failure'; Completed = @(); ResourceCounts = @(); Failed = @(@{ Id = 'sub-b'; Name = 'Sub B'; Reason = 'this run' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 1 })
        { $null = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed $Prior $S.Reports 6>$null } | Should -Not -Throw
        $After = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ })
        [int](@($After | Where-Object Id -eq 'sub-b')[0].Attempts) | Should -Be 2
    }

    It 'a failed save of the resume state after a subscription fails is named at the end, and the file is put aside so no later run skips on it (<Case>)' -ForEach @(
        @{ Case = 'put aside'; MoveFails = $false; NoFile = $false }
        @{ Case = 'cannot be put aside'; MoveFails = $true; NoFile = $false }
        @{ Case = 'no state file: a mark is made'; MoveFails = $false; NoFile = $true }
    ) {
        # Run 1 (BeforeEach) completed sub-a. This run's write-ahead save of sub-a
        # reaches the disk (its completion is out, its count is up); sub-a then
        # fails and that save does not reach the disk, so the file does not hold
        # this run's last result: the end of the run puts it aside.
        $Global:RdaCarryTestFailIds = @('sub-a')
        $S = script:Read-State -Path $script:State
        $script:ResumeStateSaveFailed = $false
        # The write-ahead save reaches the disk; the save of the failure does not.
        $Global:RdaStateSaves = 0
        Mock Set-Content -ParameterFilter { [string]$LiteralPath -like '*.resume-state-*.tmp' -and (++$Global:RdaStateSaves) -gt 1 } -MockWith { throw 'stand-in: disk full' }
        $null = & $script:SeqBlock $script:FailRoot @($script:A) $false $S.Completed @(Get-FailedAttempts -Path $script:State -Tenant 't') $S.Reports $script:Root $script:State 't' $false 6>$null
        Remove-Variable -Name RdaStateSaves -Scope Global -ErrorAction SilentlyContinue
        (script:Read-State -Path $script:State).Completed | Should -BeNullOrEmpty -Because 'the write-ahead save took the earlier completion out'
        $script:ResumeStateSaveFailed | Should -BeTrue
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$null, [ref]$null)
        $Banner = @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -like '$ResumeStateSaveFailed*' })
        $Banner.Count | Should -Be 1
        Set-Variable -Name ResumeStateSaveFailed -Value $true
        Set-Variable -Name ResumeStateFile -Value $script:State
        if ($MoveFails) { Mock Move-Item -ParameterFilter { [string]$LiteralPath -eq $script:State } -MockWith { throw 'stand-in: denied' } }
        if ($NoFile) { Remove-Item -LiteralPath $script:State -Force }
        $Lines = @(& ([scriptblock]::Create($Banner[0].Extent.Text)) 6>&1 | ForEach-Object { [string]$_ })
        if ($MoveFails)
        {
            @($Lines | Where-Object { $_ -like ('The resume state file {0} could not be written at least once this run*a -Resume or -ResumeFailedOnly run would skip it and carry its old report.' -f $script:State) }).Count | Should -Be 1
            @($Lines | Where-Object { $_ -like '*then run again without -Resume or -ResumeFailedOnly: it collects every subscription.' }).Count | Should -Be 1
            (script:Read-State -Path $script:State).Completed | Should -BeNullOrEmpty
        }
        else
        {
            $Aside = @(Get-ChildItem -LiteralPath $script:Root -Filter '.resume-state-t.json.not-saved-*' -Force)
            $Aside.Count | Should -Be 1
            @($Lines | Where-Object { $_ -like ('The resume state file {0} could not be written with this run''s results*{1}*. No -Resume run skips a subscription on it*-ResumeFailedOnly refuses to run until a run saves the resume state again.' -f $script:State, $Aside[0].FullName) }).Count | Should -Be 1
            @($Lines | Where-Object { $_ -like $(if ($NoFile) { '*an empty file * is made as a mark*' } else { '*it is put aside as *' }) }).Count | Should -Be 1
            # The next -Resume finds no state, so it skips nothing: sub-a is collected again.
            Test-Path -LiteralPath $script:State | Should -BeFalse
            @(Get-CompletedSubscriptionIds -Path $script:State -Tenant 't') | Should -BeNullOrEmpty
        }
    }

    It 'a step after collection that stops the run still puts aside a resume state the run could not save' {
        # The wrapper arms it right after "All subscriptions processed!", before the
        # output verification and the bundle, and disarms it where the end does it.
        $Src = Get-Content -LiteralPath $script:WrapperPath -Raw
        $Done = $Src.IndexOf('Write-Host "All subscriptions processed!" -ForegroundColor Green')
        $Arm = $Src.IndexOf('$script:RdaNotSavedOnExit = $true')
        $Verify = $Src.IndexOf('ERROR: Per-subscription output verification failed.')
        $Done | Should -BeGreaterThan 0
        $Arm | Should -BeGreaterThan $Done
        $Arm | Should -BeLessThan $Verify
        # Exit-Wrapper, run in its own process (it ends the process).
        $Functions = Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1'
        $Probe = Join-Path $script:Root 'probe.ps1'
        @"
. '$Functions'
Set-Content -LiteralPath '$($script:State)' -Value '{}'
`$script:ResumeStateSaveFailed = `$true
`$script:RdaNotSavedStateFile = '$($script:State)'
`$script:RdaNotSavedOnExit = `$true
`$WrapperTranscriptStarted = `$false
Exit-Wrapper -Code 2
"@ | Set-Content -LiteralPath $Probe -Encoding utf8
        $Out = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $Probe 2>&1 | ForEach-Object { [string]$_ })
        $LASTEXITCODE | Should -Be 2
        # Before the arm (an early exit) under strict mode, Exit-Wrapper reads
        # the unset switches without an error.
        $Early = Join-Path $script:Root 'probe-early.ps1'
        @"
Set-StrictMode -Version Latest
. '$Functions'
`$WrapperTranscriptStarted = `$false
Exit-Wrapper -Code 1
"@ | Set-Content -LiteralPath $Early -Encoding utf8
        $EarlyOut = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $Early 2>&1 | ForEach-Object { [string]$_ })
        $LASTEXITCODE | Should -Be 1
        @($EarlyOut | Where-Object { $_ -like '*cannot be retrieved*' -or $_ -like '*has not been set*' }) | Should -BeNullOrEmpty
        $global:LASTEXITCODE = 0
        Test-Path -LiteralPath $script:State | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Root -Filter '.resume-state-t.json.not-saved-*' -Force).Count | Should -Be 1
        @($Out | Where-Object { $_ -like '*FAILED (resume state not saved)*' }).Count | Should -Be 1
    }

    It 'a save of the resume state that reaches the disk after one that failed clears the flag, and the banner is quiet without a state file' {
        $script:ResumeStateSaveFailed = $true
        Save-CompletedSubscriptionIds -Path $script:State -Tenant 't' -Ids @() -FailedAttempts @() -Reports @()
        $script:ResumeStateSaveFailed | Should -BeFalse -Because 'the file now holds the whole state again'
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$null, [ref]$null)
        # The run starts with the flag down.
        @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Extent.Text -eq '$ResumeStateSaveFailed = $false' }).Count | Should -Be 1
        $Banner = @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -like '$ResumeStateSaveFailed -and *' })
        $Banner.Count | Should -Be 1
        Set-Variable -Name ResumeStateSaveFailed -Value $true
        Set-Variable -Name ResumeStateFile -Value (Join-Path $script:Root 'no-such-state.json')
        Set-Variable -Name RunClean -Value $true
        @(& ([scriptblock]::Create($Banner[0].Extent.Text)) 6>&1) | Should -BeNullOrEmpty -Because 'a clean run leaves nothing owed, so nothing a -Resume could skip on'
        @(Get-ChildItem -LiteralPath $script:Root -Filter 'no-such-state.json.not-saved-*' -Force) | Should -BeNullOrEmpty
    }

    It 'a run whose saves of the resume state all reach the disk says nothing about it' {
        $Global:RdaCarryTestFailIds = @('sub-a')
        $S = script:Read-State -Path $script:State
        $script:ResumeStateSaveFailed = $false
        $null = & $script:SeqBlock $script:FailRoot @($script:A) $false $S.Completed @(Get-FailedAttempts -Path $script:State -Tenant 't') $S.Reports $script:Root $script:State 't' $false 6>$null
        (script:Read-State -Path $script:State).Completed | Should -BeNullOrEmpty
        $script:ResumeStateSaveFailed | Should -BeFalse
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

    It 'after the state is put aside, -ResumeFailedOnly refuses to run (exit 2), -Resume collects every subscription, and a clean run removes the mark' {
        Remove-Item -LiteralPath $script:State -Force
        $Mark = Join-Path $script:Root '.resume-state-t.json.not-saved-20260101000000000'
        Set-Content -LiteralPath $Mark -Value '{}'
        $Top = @([System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$null, [ref]$null).EndBlock.Statements)
        $Check = @($Top | Where-Object { ($_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -in '$StatePutAside', '$StatePutAsideOnly') -or ($_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$ResumeFailedOnly -and $StatePutAsideOnly') })
        $Check.Count | Should -Be 3
        $CheckBlock = [scriptblock]::Create("param(`$InventoryRoot, `$ResumeStateFile, `$ResumeFailedOnly)`nfunction Exit-Wrapper { param([int]`$Code) throw ('Exit-Wrapper ' + `$Code) }`n" + (@($Check | ForEach-Object { $_.Extent.Text }) -join "`n"))
        $Said = @()
        { & $CheckBlock $script:Root $script:State $true 6>&1 | ForEach-Object { $Said += [string]$_ } } | Should -Throw 'Exit-Wrapper 2'
        { & $CheckBlock $script:Root $script:State $false 6>$null } | Should -Not -Throw
        # -Resume: no state, so it skips nothing and says why.
        $Start = @(& $script:StartupBlock $script:Root 't' $script:State $true 6>&1)
        $Lines = @($Start | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData } | Where-Object { $_ -like 'Resume mode:*' })
        $Lines | Should -Be @(('Resume mode: an earlier run could not save the resume state (put aside as {0}); no subscription is skipped as done.' -f $Mark))
        # A clean run that clears a state saved since removes the mark.
        Save-CompletedSubscriptionIds -Path $script:State -Tenant 't' -Ids @('sub-a') -FailedAttempts @() -Reports @()
        $IsClean = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$RunClean' })
        $Clean = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$RunClean -and (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf)' })
        $Marks = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$RunClean -or (-not $ResumeStateSaveFailed -and (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf))' })
        $Marks.Count | Should -Be 1
        $End = [scriptblock]::Create("param(`$ResumeStateFile, `$StatePutAside, `$Owed, `$ResumeStateSaveFailed = `$false)`n`$FailedSubscriptions = @(); `$RetryOwedCount = `$Owed; `$NotCollected = @(); `$UnreadableStreamFiles = @(); `$LeftStreamFiles = @()`n" + $IsClean[0].Extent.Text + "`n" + $Clean[0].Extent.Text + "`n" + $Marks[0].Extent.Text)
        & $End $script:State @($Mark) 0 6>$null
        Test-Path -LiteralPath $Mark | Should -BeFalse
        # A clean run whose last save failed removes it too: nothing is owed.
        Set-Content -LiteralPath $Mark -Value '{}'
        & $End $script:State @($Mark) 0 $true 6>$null
        Test-Path -LiteralPath $Mark | Should -BeFalse
        # A run that is not clean but saved its state (which holds the mark's
        # failures) removes the mark too, so an older mark cannot bring back a
        # failure a later run cleared.
        Set-Content -LiteralPath $Mark -Value '{}'
        Save-CompletedSubscriptionIds -Path $script:State -Tenant 't' -Ids @() -FailedAttempts @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'r'; Attempts = 1 }) -Reports @()
        & $End $script:State @($Mark) 1 6>$null
        Test-Path -LiteralPath $script:State | Should -BeTrue
        Test-Path -LiteralPath $Mark | Should -BeFalse
        # One that cannot be removed is named.
        Set-Content -LiteralPath $Mark -Value '{}'
        Mock Remove-Item -ParameterFilter { [string]$LiteralPath -eq $Mark } -MockWith { throw 'stand-in: locked' }
        $Said = @(& $End $script:State @($Mark) 1 6>&1 | ForEach-Object { [string]$_ })
        @($Said | Where-Object { $_ -like ('WARNING: Could not remove {0}*stand-in: locked*Delete it*' -f $Mark) }).Count | Should -Be 1
    }

    It 'reads only the failures of a state put aside as not saved, never its completions, so no retry entry is lost' {
        Move-Item -LiteralPath $script:State -Destination ($script:State + '.not-saved-20260101000000000')
        $Start = @(& $script:StartupBlock $script:Root 't' $script:State $true 6>$null)
        $Loaded = $Start | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['CompletedIds'] } | Select-Object -Last 1
        @($Loaded.FailedAttempts | ForEach-Object Id) | Should -Be @('sub-c') -Because 'sub-c (for example disabled, not in this run) stays owed'
        @($Loaded.CompletedIds) | Should -BeNullOrEmpty -Because 'sub-a is collected again'
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

    It 'collects again a completed subscription the current-format state file lists without its report' {
        # An older version could fold a stream file with no Reports and write
        # the unified file with the id but no record (CompletedReports present).
        [ordered]@{ TenantID = 't'; CompletedSubscriptionIds = @('sub-a', 'sub-b'); FailedAttempts = @(); CompletedReports = @(); LastUpdated = '2026-01-01T00:00:00Z' } | ConvertTo-Json | Set-Content -LiteralPath $script:State -Encoding utf8
        $Start = @(& $script:StartupBlock $script:Root 't' $script:State $true 6>&1)
        $Loaded = $Start | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['CompletedIds'] } | Select-Object -Last 1
        $Lines = @($Start | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData } | Where-Object { $_ -like 'Resume mode:*' })
        $Lines | Should -Be @('Resume mode: the resume state lists 2 completed subscription(s) with no recorded report, so they will be collected again for the bundle to hold their reports.')
        @($Loaded.CompletedIds) | Should -BeNullOrEmpty
    }

    It 'does not count as without a report a completed subscription an interrupted stream file lists as failed' {
        $Zip = Join-Path $script:Root 'sub-a-report.zip'
        Set-Content -LiteralPath $Zip -Value 'zip'
        $Record = New-CompletedReportRecord -InventoryRoot $script:Root -Id 'sub-a' -Name 'Sub A' -ZipPath $Zip -Obfuscated $false
        Save-CompletedSubscriptionIds -Path $script:State -Tenant 't' -Ids @('sub-a') -FailedAttempts @() -Reports @($Record)
        @{ Tenant = 't'; StreamId = '0'; Completed = @(); FailedAttempts = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'stand-in'; Attempts = 1 }); Reports = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        $Start = @(& $script:StartupBlock $script:Root 't' $script:State $true 6>&1)
        $Lines = @($Start | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData } | Where-Object { $_ -like 'Resume mode:*' })
        @($Lines | Where-Object { $_ -like '*no recorded report*' -or $_ -like '*written by an older version*' }) | Should -BeNullOrEmpty -Because 'sub-a had its record; it is collected again because it failed'
        $Lines | Should -Be @('Resume mode: no completed subscriptions to skip; processing all subscriptions.') -Because 'a state file is there, so the run does not say none was found'
    }

    It 'folds in at the start only the failures of a per-stream file a cut-off run left, never its completions (fail-safe rule; <Case>)' -ForEach @(
        @{ Case = 'a file with a run id'; FileRunId = 'run-a' }
        @{ Case = 'a file of an older version (no run id)'; FileRunId = '' }
    ) {
        Save-CompletedSubscriptionIds -Path $script:State -Tenant 't' -Ids @() -FailedAttempts @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = (Get-Date).ToUniversalTime().ToString('o'); Reason = 'newer failure'; Attempts = 1 }) -Reports @()
        $Zip = Join-Path $script:Root 'sub-x-report.zip'
        Set-Content -LiteralPath $Zip -Value 'zip'
        $Record = New-CompletedReportRecord -InventoryRoot $script:Root -Id 'sub-x' -Name 'Sub X' -ZipPath $Zip -Obfuscated $false
        $File = Join-Path $script:Root '.resume-state-t-stream-0.json'
        $Obj = [ordered]@{ Tenant = 't'; StreamId = '0'; Completed = @('sub-x'); FailedAttempts = @(@{ Id = 'sub-y'; Name = 'Sub Y'; LastFailedAt = (Get-Date).ToUniversalTime().ToString('o'); Reason = 'file failure'; Attempts = 1 }); Reports = @($Record) }
        if ($FileRunId) { $Obj.RunId = $FileRunId }
        $Obj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $File -Encoding utf8
        $Start = @(& $script:StartupBlock $script:Root 't' $script:State $true 6>$null)
        $Loaded = $Start | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['CompletedIds'] } | Select-Object -Last 1
        @($Loaded.FailedAttempts | ForEach-Object { [string]$_.Id }) | Should -Contain 'sub-y' -Because 'a failure is never lost'
        @($Loaded.CompletedIds) | Should -Not -Contain 'sub-x' -Because 'the cut-off run never proved its result saved, so it does not end the newer failure'
        @(Get-FailedAttempts -Path $script:State -Tenant 't' | ForEach-Object { [string]$_.Id } | Sort-Object) | Should -Be @('sub-x', 'sub-y')
        Test-Path -LiteralPath $File | Should -BeFalse -Because 'a folded file is removed'
    }

    It 'counts only what the state file lists, and no completion an interrupted parallel run left without a report' {
        # Two ids in the state file (the fold joins a one-id list and the stranded ids
        # into one string), and an older version's stream file: sub-x completed, no
        # Reports. With no report record a later -Resume could carry, sub-x does not
        # count as completed either: it is collected again, like the two older-version
        # ids, and never skipped with no zip to carry.
        [ordered]@{ TenantID = 't'; CompletedSubscriptionIds = @('sub-a', 'sub-b'); FailedAttempts = @(); LastUpdated = '2026-01-01T00:00:00Z' } | ConvertTo-Json | Set-Content -LiteralPath $script:State -Encoding utf8
        @{ Tenant = 't'; StreamId = '0'; Completed = @('sub-x'); FailedAttempts = @() } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        $Start = @(& $script:StartupBlock $script:Root 't' $script:State $true 6>&1)
        $Loaded = $Start | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['CompletedIds'] } | Select-Object -Last 1
        $Lines = @($Start | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData } | Where-Object { $_ -like 'Resume mode:*' })

        $Lines | Should -Be @(
            'Resume mode: the resume state was written by an older version, so 2 subscription(s) will be collected again for the bundle to hold their reports.')
        @($Loaded.CompletedIds) | Should -BeNullOrEmpty
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
