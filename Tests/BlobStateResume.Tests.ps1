# Blob-backed resume state - live pod-reschedule cycle (opt-in / live-sandbox)
#
# Exercises the AKS durability path end to end against a REAL Azure Blob
# container, using the actual shipping helpers (New-StateBlobContext,
# Save-StateBlob, Read-StateBlob, Get-StateBlobName, Get-SubscriptionDelta):
#
#   pod A: write resume state through to blob (write-through)
#   pod death: local state is destroyed (emptyDir gone)
#   pod B (rescheduled, same shard): read the state BLOB-FIRST and recover
#   reconcile: classify a moved end-universe (Vanished / New / Incomplete)
#
# This is the automated form of the manual pod-death verification. The project
# does NOT mock Azure cmdlets, so this is a LIVE-SANDBOX test: it is opt-in and
# self-skips unless the target is provided, keeping CI (which has no Azure)
# green. It never runs the wrapper - only the state helpers - so its only cost
# is a few tiny blob writes/deletes that it cleans up.
#
# Enable by pointing it at a storage account the current Az identity can write
# (needs "Storage Blob Data Contributor"):
#   $env:TEST_STATE_BLOB_ACCOUNT = '<storageaccount>'      # required to run
#   $env:TEST_STATE_BLOB_CONTAINER = 'rda-output'          # optional (default)
#   Invoke-Pester ./Tests/BlobStateResume.Tests.ps1 -Output Detailed
#
# Leaves no artifacts: every blob it writes is removed in AfterAll, under a
# unique per-run _state test prefix so it never touches real run state.

# Evaluated at DISCOVERY time so -Skip can gate the whole suite when the target
# is absent (a BeforeAll-set variable is too late for -Skip).
$script:BlobResumeEnabled = -not [string]::IsNullOrWhiteSpace($env:TEST_STATE_BLOB_ACCOUNT)

BeforeAll {
    $script:FunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1'
    if (-not (Test-Path $script:FunctionsPath)) { throw "Could not find shared functions file at $script:FunctionsPath" }
    . $script:FunctionsPath

    $TargetFunctions = @('New-StateBlobContext', 'Save-StateBlob', 'Read-StateBlob', 'Get-StateBlobName', 'Split-BlobContainerUri', 'Get-SubscriptionDelta')
    foreach ($Fn in $TargetFunctions)
    {
        if (-not (Get-Command $Fn -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Expected function '$Fn' to be defined by $script:FunctionsPath, but it was not. Has it been renamed or removed?"
        }
    }

    # Read the env directly here: $script:BlobResumeEnabled is a DISCOVERY-time
    # value (used only by the Describe -Skip) and is not reliably in scope in this
    # run-time block, so gating on it here would wrongly early-return under -Skip:false.
    if ([string]::IsNullOrWhiteSpace($env:TEST_STATE_BLOB_ACCOUNT)) { return }

    $script:Account = $env:TEST_STATE_BLOB_ACCOUNT
    $script:Container = if ([string]::IsNullOrWhiteSpace($env:TEST_STATE_BLOB_CONTAINER)) { 'rda-output' } else { $env:TEST_STATE_BLOB_CONTAINER }
    # Unique per-run prefix so parallel/other runs and REAL run state are never
    # touched; also namespaces the blob under a _state area like production.
    $script:Prefix = ('itest/blobresume-{0}/' -f ([guid]::NewGuid().ToString('N')))
    $script:Tenant = 'itest-tenant'
    $script:Ctx = New-StateBlobContext -Account $script:Account
    $script:BlobName = Get-StateBlobName -Prefix $script:Prefix -Tenant $script:Tenant -ShardIndex 1 -ShardCount 2 -StreamId -1
    $script:LocalState = Join-Path ([System.IO.Path]::GetTempPath()) ('.resume-state-itest-' + [guid]::NewGuid().ToString('N') + '.json')
}

AfterAll {
    if ([string]::IsNullOrWhiteSpace($env:TEST_STATE_BLOB_ACCOUNT)) { return }
    if ($script:Ctx -and $script:Container -and $script:BlobName)
    {
        try { Remove-AzStorageBlob -Container $script:Container -Blob $script:BlobName -Context $script:Ctx -Force -ErrorAction Stop } catch {}
    }
    if ($script:LocalState -and (Test-Path $script:LocalState)) { Remove-Item -LiteralPath $script:LocalState -Force -ErrorAction SilentlyContinue }
}

# NOTE: the first two It blocks form an ordered pod-cycle narrative and share
# $script:BlobName - the second reads back the state the first wrote through to
# blob. This intentional ordering dependency mirrors the real pod A -> pod B
# handoff and relies on Pester v5 executing It blocks in file order. The second
# It is therefore not standalone; run the whole Describe, not a single It.
Describe 'Blob-backed resume state - live pod-reschedule cycle' -Skip:(-not $script:BlobResumeEnabled) {

    It 'write-through then blob-first read recovers the completed set and start snapshot after local state is lost' {
        $StartIds = @('sub-a', 'sub-b', 'sub-c', 'sub-d')
        $StateObj = [pscustomobject]@{
            TenantID                 = $script:Tenant
            CompletedSubscriptionIds = @('sub-a', 'sub-b')
            FailedAttempts           = @()
            EnumeratedAtStart        = [pscustomobject]@{ CapturedUtc = (Get-Date).ToString('o'); SubscriptionIds = $StartIds }
            LastUpdated              = (Get-Date).ToString('o')
        }
        # pod A: local atomic write, then write-through to blob.
        $StateObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:LocalState -Encoding utf8
        (Save-StateBlob -Context $script:Ctx -Container $script:Container -BlobName $script:BlobName -File $script:LocalState -BestEffort) | Should -BeTrue

        # pod death: emptyDir gone.
        Remove-Item -LiteralPath $script:LocalState -Force
        (Test-Path $script:LocalState) | Should -BeFalse

        # pod B (rescheduled, same shard): blob-first recovery.
        $Recovered = Read-StateBlob -Context $script:Ctx -Container $script:Container -BlobName $script:BlobName
        $Recovered | Should -Not -BeNullOrEmpty
        (@($Recovered.CompletedSubscriptionIds) -join ',') | Should -Be 'sub-a,sub-b'
        (@($Recovered.EnumeratedAtStart.SubscriptionIds).Count) | Should -Be 4
    }

    It 'reconciles a moving universe correctly after blob-first recovery (Vanished / New / Incomplete)' {
        $Recovered = Read-StateBlob -Context $script:Ctx -Container $script:Container -BlobName $script:BlobName
        $Recovered | Should -Not -BeNullOrEmpty
        $StartIds = @($Recovered.EnumeratedAtStart.SubscriptionIds)
        $CompletedIds = @($Recovered.CompletedSubscriptionIds)
        # End universe moved mid-run: sub-d deleted, sub-e created.
        $EndIds = @('sub-a', 'sub-b', 'sub-c', 'sub-e')
        $Delta = Get-SubscriptionDelta -StartIds $StartIds -EndIds $EndIds -CompletedIds $CompletedIds
        $Delta.Vanished   | Should -Be @('sub-d')
        $Delta.New        | Should -Be @('sub-e')
        $Delta.Incomplete | Should -Be @('sub-c')
    }

    It 'reports blob absence as start-fresh ($null), not an error' {
        $AbsentName = Get-StateBlobName -Prefix $script:Prefix -Tenant 'no-such-tenant' -ShardIndex 0 -ShardCount 1 -StreamId -1
        $Result = Read-StateBlob -Context $script:Ctx -Container $script:Container -BlobName $AbsentName
        $Result | Should -BeNullOrEmpty
    }
}
