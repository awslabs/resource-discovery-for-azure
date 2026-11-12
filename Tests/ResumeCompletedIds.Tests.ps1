#
# Run-AllSubscriptions.ps1 keeps the ids of completed subscriptions in the
# resume state file so a later -Resume run skips them. The list must hold one
# entry per subscription whether it starts empty, with one id, or with several.
#
#   - Sequential path, end to end without Azure: the wrapper's startup (seeding
#     the list from the state file, folding in per-stream state, the resume
#     message) and its sequential loop are lifted from its AST and run as
#     written, against a stand-in ResourceInventory.ps1 that records which
#     subscriptions it was asked to process and writes a report zip for each,
#     as a successful run of the real script does.
#   - The other places that add to the same list: the startup fold of state
#     left by an interrupted parallel run, the one-subscription fallback of
#     -ParallelStreams, and the end-of-run merge of per-stream state.
#   Assertions read the state file the wrapper wrote and what a following
#   -Resume run processed again.
#
# Run with: Invoke-Pester ./Tests/ResumeCompletedIds.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('ResumeIdsTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null

    # Subscription ids have the 36-character GUID form of real ones.
    function script:New-TestSub
    {
        param([int]$N, [string]$Name)
        return [pscustomobject]@{ Id = ('{0:d8}-0000-4000-8000-{0:d12}' -f $N); Name = $Name; State = 'Enabled' }
    }
    $script:A = script:New-TestSub -N 1 -Name 'Sub A'
    $script:B = script:New-TestSub -N 2 -Name 'Sub B'
    $script:C = script:New-TestSub -N 3 -Name 'Sub C'
    $script:All = @($script:A, $script:B, $script:C)

    # Stand-in for ResourceInventory.ps1: records the subscription it was given,
    # writes a report zip under the case folder and leaves the globals the
    # wrapper reads afterwards, $Global:ZipOutputFile naming that zip as a
    # successful run of the real script does. The resource count is set both as
    # the list and as the count, so the stand-in reports one resource whichever
    # of the two the wrapper reads.
    $script:FakeRoot = Join-Path $script:TestBase 'fake-tool'
    New-Item -ItemType Directory -Path $script:FakeRoot -Force | Out-Null
    $FakeInner = @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
$Global:RdaIdsTestProcessed += @($SubscriptionID)
$Folder = Join-Path $Global:RdaIdsTestRoot ('ResourcesReport' + $SubscriptionID)
New-Item -ItemType Directory -Path $Folder -Force | Out-Null
$Inv = Join-Path $Folder ('Inventory_ResourcesReport_' + $SubscriptionID + '.json')
Set-Content -LiteralPath $Inv -Value '{}' -Encoding utf8
$Global:ZipOutputFile = Join-Path $Folder ('ResourcesReport_' + $SubscriptionID + '.zip')
Compress-Archive -LiteralPath $Inv -DestinationPath $Global:ZipOutputFile -Force
$Global:Resources = @(1)
$Global:ResourceCount = 1
$Global:LASTEXITCODE = 0
'@
    Set-Content -LiteralPath (Join-Path $script:FakeRoot 'ResourceInventory.ps1') -Value $FakeInner -Encoding utf8

    # --- Wrapper code lifted from its AST and run as written ------------------
    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
    $Top = @($Ast.EndBlock.Statements)

    # Startup: from the assignment that seeds $CompletedIds through the
    # "Resume mode: ..." message, which takes in the per-stream fold between them.
    # The statements between that and the loop (the -ResumeFailedOnly filter,
    # the access check, auto-tuning) are left out: they call Azure or do not
    # change the completed list.
    $From = -1
    $To = -1
    for ($i = 0; $i -lt $Top.Count; $i++)
    {
        if ($From -lt 0 -and $Top[$i] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $Top[$i].Left.Extent.Text -eq '$CompletedIds') { $From = $i }
        if ($From -ge 0 -and $Top[$i] -is [System.Management.Automation.Language.IfStatementAst] -and $Top[$i].Clauses[0].Item1.Extent.Text -eq '$Resume') { $To = $i; break }
    }
    if ($From -lt 0 -or $To -lt 0) { throw 'Expected the $CompletedIds seed and the following if ($Resume) message in the wrapper.' }
    $StartupText = (@($Top[$From..$To] | ForEach-Object { $_.Extent.Text }) -join "`n")

    # The sequential loop: the body of `if ($ParallelStreams -le 1)`.
    $SeqIf = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq '$ParallelStreams -le 1' }, $true))
    if ($SeqIf.Count -ne 1) { throw "Expected one 'if (`$ParallelStreams -le 1)' in the wrapper, found $($SeqIf.Count)." }
    $SeqText = $SeqIf[0].Clauses[0].Item2.Extent.Text -replace '\$PSScriptRoot', '$FakeScriptRoot'

    # The loop's starting values: every top-level assignment of an empty value
    # (0, $null, @(), @{}) between the resume message and
    # `if ($ParallelStreams -le 1)`, in order. This picks up the counters and the
    # empty inner-script passthrough; the statements that fill the passthrough
    # are left out, as the stand-in ignores it.
    $Split = [array]::IndexOf($Top, $SeqIf[0])
    if ($Split -le $To) { throw 'Expected the top-level if ($ParallelStreams -le 1) after the resume message in the wrapper.' }
    $Inits = @($Top[($To + 1)..($Split - 1)] | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $_.Right.Extent.Text -in @('0', '$null', '@()', '@{}')
        })
    if (-not ($Inits | Where-Object { $_.Left.Extent.Text -eq '$InventoryPassthrough' })) { throw 'Expected $InventoryPassthrough = @{} before the top-level if ($ParallelStreams -le 1) in the wrapper.' }
    $SetupText = (@($Inits | ForEach-Object { $_.Extent.Text }) -join "`n")

    # The one-subscription fallback of the parallel path.
    $OneIf = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq '$StreamCount -le 1' }, $true))
    if ($OneIf.Count -ne 1) { throw "Expected one 'if (`$StreamCount -le 1)' in the wrapper, found $($OneIf.Count)." }
    $OneText = $OneIf[0].Extent.Text -replace '\$PSScriptRoot', '$FakeScriptRoot'

    # The end-of-run merge of per-stream state: the orchestration try-body from
    # its discovery of per-stream files to its end.
    $Orch = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.TryStatementAst] -and $args[0].Body.Extent.Text -match [regex]::Escape("`$WorkerScript = Join-Path `$PSScriptRoot 'Run-AllSubscriptions.Stream.ps1'") }, $true))
    if ($Orch.Count -ne 1) { throw "Expected one stream-orchestration try block in the wrapper, found $($Orch.Count)." }
    $Body = @($Orch[0].Body.Statements)
    $MergeStart = -1
    for ($i = 0; $i -lt $Body.Count; $i++)
    {
        if ($Body[$i] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $Body[$i].Left.Extent.Text -eq '$AllStreamFiles') { $MergeStart = $i; break }
    }
    if ($MergeStart -lt 0) { throw 'Expected the end-of-run merge of per-stream state in the wrapper.' }
    $MergeText = (@($Body[$MergeStart..($Body.Count - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n")

    $Prelude = "param(`$FakeScriptRoot, `$InventoryRoot, `$ResumeStateFile, `$TenantID, `$Subscriptions, `$Resume)`n" +
    "`$ResumeFailedOnly = `$false; `$FailedSubscriptions = @()`n" +
    $StartupText + "`n" + $SetupText + "`n"
    $script:SequentialRun = [scriptblock]::Create($Prelude + '. ' + $SeqText)
    $script:FallbackRun = [scriptblock]::Create($Prelude + $OneText)
    $script:StreamMergeRun = [scriptblock]::Create($Prelude + $MergeText)

    # Run one lifted block against a case folder. Returns the host lines it
    # printed and the names of the subscriptions the stand-in processed.
    function script:Invoke-Wrapper
    {
        param([scriptblock]$Block, [string]$Root, [object[]]$Subs, [bool]$Resume = $false)
        $Global:RdaIdsTestProcessed = @()
        $Global:RdaIdsTestRoot = $Root
        $Out = @(& $Block $script:FakeRoot $Root (Join-Path $Root '.resume-state-t.json') 't' $Subs $Resume 6>&1)
        $Text = @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $Names = @($Global:RdaIdsTestProcessed | ForEach-Object { $Id = $_; ($script:All | Where-Object { $_.Id -eq $Id }).Name })
        return [pscustomobject]@{ Text = $Text; Processed = ($Names -join ', ') }
    }

    # The completed ids in the state file, named by subscription. Anything that
    # is not one of the test subscriptions' ids is shown with its length.
    function script:Get-StateIds
    {
        param([string]$Root)
        $Ids = @((Get-Content -LiteralPath (Join-Path $Root '.resume-state-t.json') -Raw | ConvertFrom-Json).CompletedSubscriptionIds)
        $Labels = @($Ids | ForEach-Object {
                $Id = $_
                $Sub = $script:All | Where-Object { $_.Id -eq $Id }
                if ($null -eq $Id) { '<null>' }
                elseif ($Sub) { $Sub.Name }
                else { '<not a subscription id, {0} characters>' -f ([string]$Id).Length }
            } | Sort-Object)
        return ('{0} id(s): {1}' -f $Ids.Count, ($Labels -join ', '))
    }

    function script:Get-ResumeLine
    {
        param([string[]]$Text)
        return @($Text | Where-Object { $_ -like 'Resume mode:*' }) -join ' | '
    }

    function script:Save-TestState
    {
        param([string]$Root, [object[]]$Subs)
        Save-CompletedSubscriptionIds -Path (Join-Path $Root '.resume-state-t.json') -Tenant 't' -Ids @($Subs | ForEach-Object { $_.Id })
    }

    # A per-stream state file as Run-AllSubscriptions.Stream.ps1 writes it.
    function script:Save-TestStreamState
    {
        param([string]$Root, [int]$StreamId, [object[]]$Subs)
        @{ Tenant = 't'; StreamId = [string]$StreamId; Completed = @($Subs | ForEach-Object { $_.Id }); FailedAttempts = @() } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Root (".resume-state-t-stream-{0}.json" -f $StreamId)) -Encoding utf8
    }

    function script:New-CaseRoot
    {
        $Root = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        return $Root
    }
}

AfterAll {
    Remove-Variable -Name RdaIdsTestProcessed, RdaIdsTestRoot -Scope Global -ErrorAction SilentlyContinue
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe 'Sequential run: the resume state keeps one id per completed subscription' {
    BeforeEach { $script:Root = script:New-CaseRoot }

    It 'no earlier state, two subscriptions complete: two ids' {
        $null = script:Invoke-Wrapper -Block $script:SequentialRun -Root $script:Root -Subs @($script:A, $script:B)
        script:Get-StateIds -Root $script:Root | Should -Be '2 id(s): Sub A, Sub B'
    }

    It 'one id from an earlier run, one more completes under -Resume: two ids' {
        script:Save-TestState -Root $script:Root -Subs @($script:A)
        $R = script:Invoke-Wrapper -Block $script:SequentialRun -Root $script:Root -Subs @($script:A, $script:B) -Resume $true
        $R.Processed | Should -Be 'Sub B'
        script:Get-StateIds -Root $script:Root | Should -Be '2 id(s): Sub A, Sub B'
    }

    It 'no earlier state, one subscription completes: one id' {
        $null = script:Invoke-Wrapper -Block $script:SequentialRun -Root $script:Root -Subs @($script:A)
        script:Get-StateIds -Root $script:Root | Should -Be '1 id(s): Sub A'
    }

    It 'a -Resume run after <Label> skips both completed subscriptions' -TestCases @(
        @{ Label = 'two completed in one run'; Prior = 0 },
        @{ Label = 'one completed in each of two runs'; Prior = 1 }
    ) {
        if ($Prior -eq 1)
        {
            script:Save-TestState -Root $script:Root -Subs @($script:A)
            $null = script:Invoke-Wrapper -Block $script:SequentialRun -Root $script:Root -Subs @($script:A, $script:B) -Resume $true
        }
        else
        {
            $null = script:Invoke-Wrapper -Block $script:SequentialRun -Root $script:Root -Subs @($script:A, $script:B)
        }
        $R = script:Invoke-Wrapper -Block $script:SequentialRun -Root $script:Root -Subs $script:All -Resume $true
        $R.Processed | Should -Be 'Sub C'
        script:Get-ResumeLine -Text $R.Text | Should -Be 'Resume mode: 2 previously completed subscription(s) will be skipped.'
        script:Get-StateIds -Root $script:Root | Should -Be '3 id(s): Sub A, Sub B, Sub C'
    }

    It 'a state file holding a null id, as saved after a failed first subscription, reads as no completed subscriptions' {
        $Failed = @{ Id = $script:A.Id; Name = $script:A.Name; LastFailedAt = (Get-Date).ToString('o'); Reason = 'stand-in failure'; Attempts = 1 }
        @{ TenantID = 't'; CompletedSubscriptionIds = @($null); FailedAttempts = @($Failed); LastUpdated = (Get-Date).ToString('o') } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t.json') -Encoding utf8
        $R = script:Invoke-Wrapper -Block $script:SequentialRun -Root $script:Root -Subs @($script:A) -Resume $true
        script:Get-ResumeLine -Text $R.Text | Should -Be 'Resume mode: no previous state found; processing all subscriptions.'
        $R.Processed | Should -Be 'Sub A'
        script:Get-StateIds -Root $script:Root | Should -Be '1 id(s): Sub A'
    }
}

Describe 'Other places that add to the completed list, starting from one earlier id' {
    BeforeEach {
        $script:Root = script:New-CaseRoot
        script:Save-TestState -Root $script:Root -Subs @($script:A)
    }

    It 'the -Resume fold of per-stream state from an interrupted parallel run keeps both ids, and the run skips both' {
        script:Save-TestStreamState -Root $script:Root -StreamId 0 -Subs @($script:B)
        $R = script:Invoke-Wrapper -Block $script:SequentialRun -Root $script:Root -Subs $script:All -Resume $true
        $R.Processed | Should -Be 'Sub C'
        script:Get-ResumeLine -Text $R.Text | Should -Be 'Resume mode: 2 previously completed subscription(s) will be skipped.'
        script:Get-StateIds -Root $script:Root | Should -Be '3 id(s): Sub A, Sub B, Sub C'
    }

    It 'the one-subscription fallback of -ParallelStreams adds its subscription as a separate id' {
        $R = script:Invoke-Wrapper -Block $script:FallbackRun -Root $script:Root -Subs @($script:B)
        $R.Processed | Should -Be 'Sub B'
        script:Get-StateIds -Root $script:Root | Should -Be '2 id(s): Sub A, Sub B'
    }

    It 'the end-of-run merge of per-stream state adds each stream''s ids separately' {
        script:Save-TestStreamState -Root $script:Root -StreamId 0 -Subs @($script:B)
        script:Save-TestStreamState -Root $script:Root -StreamId 1 -Subs @($script:C)
        $null = script:Invoke-Wrapper -Block $script:StreamMergeRun -Root $script:Root -Subs $script:All
        script:Get-StateIds -Root $script:Root | Should -Be '3 id(s): Sub A, Sub B, Sub C'
        @(Get-ChildItem -LiteralPath $script:Root -Filter '.resume-state-t-stream-*.json' -Force).Count | Should -Be 0
    }
}
