# Blob-backed resume-state helper tests (offline / pure)
#
# Unit-tests the PURE helpers added for AKS blob-backed resume state and the
# "moving target" subscription reconciliation, in isolation - no Azure session,
# no blob account, no wrapper run:
#
#   - Split-BlobContainerUri : parses a blob container URL into
#     { Account; Container; Prefix }, prefix normalised to '' or 'x/y/'.
#   - Get-StateBlobName      : builds the shard-namespaced blob NAME for the
#     unified (StreamId < 0) and per-stream (StreamId >= 0) state files, under
#     the container's optional prefix + a dedicated _state/ area.
#   - Get-SubscriptionDelta  : classifies how the subscription universe moved
#     between the start snapshot and an end re-enumeration into disjoint
#     Vanished / New / Incomplete sets.
#
# These carry NO Azure calls, so - like Tests/RunAllSubscriptionsReconciliation.Tests.ps1
# - the shared definitions file is dot-sourced wholesale and the functions are
# exercised directly. The blob I/O functions (New-StateBlobContext,
# Save-StateBlob, Read-StateBlob, Get-StateBlobNames) are intentionally NOT
# unit-tested here: per the project's testing convention we do not mock Azure
# cmdlets; they are validated end-to-end against a live sandbox storage account.
#
# Run with: Invoke-Pester ./Tests/BlobStateReconciliation.Tests.ps1 -Output Detailed

BeforeAll {
    $script:FunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1'
    if (-not (Test-Path $script:FunctionsPath))
    {
        throw "Could not find shared functions file at $script:FunctionsPath"
    }
    . $script:FunctionsPath

    $TargetFunctions = @('Split-BlobContainerUri', 'Get-StateBlobName', 'Get-SubscriptionDelta', 'Get-StateBlobNames')
    foreach ($Fn in $TargetFunctions)
    {
        if (-not (Get-Command $Fn -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Expected function '$Fn' to be defined by $script:FunctionsPath, but it was not. Has it been renamed or removed?"
        }
    }
}

Describe 'Split-BlobContainerUri' {

    It 'parses account and container with no path prefix' {
        $Parts = Split-BlobContainerUri -Uri 'https://acct1.blob.core.windows.net/rda-output'
        $Parts.Account   | Should -Be 'acct1'
        $Parts.Container | Should -Be 'rda-output'
        $Parts.Prefix    | Should -Be ''
    }

    It 'parses a multi-segment path prefix and normalises it to end in a slash' {
        $Parts = Split-BlobContainerUri -Uri 'https://acct2.blob.core.windows.net/cont/team/run5'
        $Parts.Account   | Should -Be 'acct2'
        $Parts.Container | Should -Be 'cont'
        $Parts.Prefix    | Should -Be 'team/run5/'
    }

    It 'tolerates a trailing slash on the container URL' {
        $Parts = Split-BlobContainerUri -Uri 'https://acct3.blob.core.windows.net/cont/'
        $Parts.Container | Should -Be 'cont'
        $Parts.Prefix    | Should -Be ''
    }
}

Describe 'Get-StateBlobName' {

    It 'builds the unified (non-stream) name with no shard segment when ShardCount = 1' {
        $Name = Get-StateBlobName -Prefix '' -Tenant 'TENANT' -ShardIndex 0 -ShardCount 1 -StreamId -1
        $Name | Should -Be '_state/.resume-state-TENANT.json'
    }

    It 'inserts a shard segment when ShardCount > 1' {
        $Name = Get-StateBlobName -Prefix '' -Tenant 'TENANT' -ShardIndex 1 -ShardCount 2 -StreamId -1
        $Name | Should -Be '_state/shard-1of2/.resume-state-TENANT.json'
    }

    It 'builds a per-stream name when StreamId >= 0' {
        $Name = Get-StateBlobName -Prefix '' -Tenant 'TENANT' -ShardIndex 0 -ShardCount 1 -StreamId 3
        $Name | Should -Be '_state/.resume-state-TENANT-stream-3.json'
    }

    It 'honours the container path prefix' {
        $Name = Get-StateBlobName -Prefix 'team/run5/' -Tenant 'TENANT' -ShardIndex 0 -ShardCount 1 -StreamId -1
        $Name | Should -Be 'team/run5/_state/.resume-state-TENANT.json'
    }

    It 'produces a per-stream name whose path is under the same prefix Get-StateBlobNames lists on (naming coupling)' {
        # The parent lists per-stream blobs via Get-StateBlobNames using a list
        # prefix; each stream writes to a Get-StateBlobName path. If these two
        # diverged, a rescheduled pod would never discover the per-stream state.
        # Assert the stream name STARTS WITH the list prefix for the same shard.
        $Prefix = 'p/'
        $Tenant = 'T'
        $ShardIndex = 1
        $ShardCount = 3
        $StreamName = Get-StateBlobName -Prefix $Prefix -Tenant $Tenant -ShardIndex $ShardIndex -ShardCount $ShardCount -StreamId 2
        # Reproduce the list prefix Get-StateBlobNames builds (kept in lockstep
        # with that function): <prefix>_state/<shardseg>.resume-state-<tenant>-stream-
        $ShardSeg = 'shard-{0}of{1}/' -f $ShardIndex, $ShardCount
        $ListPrefix = '{0}_state/{1}.resume-state-{2}-stream-' -f $Prefix, $ShardSeg, $Tenant
        $StreamName.StartsWith($ListPrefix) | Should -BeTrue
    }
}

Describe 'Get-SubscriptionDelta' {

    It 'flags a subscription deleted mid-run as Vanished' {
        $D = Get-SubscriptionDelta -StartIds @('a', 'b', 'c') -EndIds @('a', 'b') -CompletedIds @('a', 'b')
        $D.Vanished | Should -Be @('c')
        $D.New      | Should -BeNullOrEmpty
    }

    It 'flags a subscription created mid-run as New' {
        $D = Get-SubscriptionDelta -StartIds @('a', 'b') -EndIds @('a', 'b', 'z') -CompletedIds @('a', 'b')
        $D.New      | Should -Be @('z')
        $D.Vanished | Should -BeNullOrEmpty
    }

    It 'keeps New and Incomplete disjoint - a mid-run-created, not-yet-done sub is only New' {
        # 'z' appeared mid-run and is not completed. It must surface as New only,
        # NOT also as Incomplete (regression guard for the set-overlap fix).
        $D = Get-SubscriptionDelta -StartIds @('a', 'b') -EndIds @('a', 'b', 'z') -CompletedIds @('a')
        $D.New        | Should -Be @('z')
        $D.Incomplete | Should -Be @('b')
        $D.Incomplete | Should -Not -Contain 'z'
    }

    It 'reports an existing-but-unprocessed sub as Incomplete' {
        $D = Get-SubscriptionDelta -StartIds @('a', 'b', 'c') -EndIds @('a', 'b', 'c') -CompletedIds @('a')
        ($D.Incomplete | Sort-Object) | Should -Be @('b', 'c')
    }

    It 'is case-insensitive on subscription ids' {
        $D = Get-SubscriptionDelta -StartIds @('AAA') -EndIds @('aaa') -CompletedIds @('aaa')
        $D.Vanished   | Should -BeNullOrEmpty
        $D.New        | Should -BeNullOrEmpty
        $D.Incomplete | Should -BeNullOrEmpty
    }

    It 'returns all-empty sets for empty input' {
        $D = Get-SubscriptionDelta -StartIds @() -EndIds @() -CompletedIds @()
        $D.Vanished   | Should -BeNullOrEmpty
        $D.New        | Should -BeNullOrEmpty
        $D.Incomplete | Should -BeNullOrEmpty
    }
}
