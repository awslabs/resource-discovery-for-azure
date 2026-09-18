# Blob-backed resume-state helper tests (offline / pure)
# Unit-tests the PURE helpers for AKS blob-backed resume state and subscription reconciliation (Split-BlobContainerUri, Get-StateBlobName, Get-StateBlobShardSegment, Get-StateBlobStreamPrefix, Get-SubscriptionDelta) with no Azure. The blob I/O functions are NOT unit-tested (project convention: don't mock Azure cmdlets; validated live); Get-StateBlobNames is only inspected STRUCTURALLY here because its coupling has a silent failure mode unreachable offline.

BeforeAll {
    $script:FunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1'
    if (-not (Test-Path $script:FunctionsPath))
    {
        throw "Could not find shared functions file at $script:FunctionsPath"
    }
    . $script:FunctionsPath

    $TargetFunctions = @('Split-BlobContainerUri', 'Get-StateBlobName', 'Get-SubscriptionDelta', 'Get-StateBlobNames',
        'Get-StateBlobShardSegment', 'Get-StateBlobStreamPrefix')
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

    It 'parses a single-segment path prefix' {
        # The remaining shape an operator passes. Kept here with the rest of this
        # function's behavioural coverage rather than in the wrapper's source-guard
        # Describe, so Split-BlobContainerUri has exactly one behavioural owner.
        $Parts = Split-BlobContainerUri -Uri 'https://acct2.blob.core.windows.net/cont/team'

        $Parts.Account | Should -Be 'acct2'
        $Parts.Container | Should -Be 'cont'
        $Parts.Prefix | Should -Be 'team/'
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
        # Discovery (Get-StateBlobNames) lists per-stream blobs by a list prefix; each stream writes a Get-StateBlobName path. If they diverge, a rescheduled pod never finds the per-stream state and silently redoes finished work. Assert against the shared Get-StateBlobStreamPrefix, not a re-derived copy (which would verify the test's own copy, not the code).
        # Residue: this only narrows drift to the ARGUMENT surface - it substitutes the helper and never calls Get-StateBlobNames (needs Azure), so an inline prefix there, or a wrong -ShardIndex/-ShardCount, stays green; the structural It below covers that offline.
        $Prefix = 'p/'
        $Tenant = 'T'
        $ShardIndex = 1
        $ShardCount = 3

        $StreamName = Get-StateBlobName -Prefix $Prefix -Tenant $Tenant -ShardIndex $ShardIndex -ShardCount $ShardCount -StreamId 2
        $ListPrefix = Get-StateBlobStreamPrefix -Prefix $Prefix -Tenant $Tenant -ShardIndex $ShardIndex -ShardCount $ShardCount

        $StreamName.StartsWith($ListPrefix) | Should -BeTrue -Because 'a written per-stream blob must be discoverable by the listing that looks for it'
        $StreamName | Should -Be ('{0}2.json' -f $ListPrefix) -Because 'the per-stream name is exactly the list prefix plus the stream id'
    }

    It 'the DISCOVERY path builds its prefix from the shared owner, not its own copy' {
        # Get-StateBlobNames calls Get-AzStorageBlob (no offline run), so inspect its body instead: structural and weaker, but fails the moment discovery grows a second copy of the layout - the regression that makes a rescheduled pod find nothing.
        # Excise comments before matching (prose here discusses '_state/', so a clarifying comment inside the function would trip the ban with a misleading message) and fail loud rather than match an empty body, which would satisfy the ban vacuously.
        $Raw = (Get-Command Get-StateBlobNames).ScriptBlock.ToString()
        $Tokens = $null
        $ParseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($Raw, [ref]$Tokens, [ref]$ParseErrors)
        $Builder = [System.Text.StringBuilder]::new($Raw)
        foreach ($C in @($Tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending))
        {
            $Len = $C.Extent.EndOffset - $C.Extent.StartOffset
            if ($Len -gt 0 -and ($C.Extent.StartOffset + $Len) -le $Builder.Length) { $null = $Builder.Remove($C.Extent.StartOffset, $Len) }
        }
        $Body = $Builder.ToString()

        $Body | Should -Not -BeNullOrEmpty -Because 'an empty body would satisfy the ban below vacuously'
        $Body | Should -Match 'Get-AzStorageBlob' -Because 'sanity: this really is the discovery function body'

        $Body | Should -Match 'Get-StateBlobStreamPrefix' -Because 'discovery must ask the shared owner for its list prefix'
        $Body | Should -Not -Match '_state/' -Because 'a literal _state/ in discovery means it rebuilt the layout itself'
    }

    It 'names stream 0 as a per-stream file, not as the shard unified file' {
        # StreamId 0 is the boundary of the 'if ($StreamId -ge 0)' selector, and
        # streams are 0-based, so stream 0 exists in EVERY parallel run. If that
        # predicate ever became -gt 0, stream 0's state would be written to the shard's
        # UNIFIED blob name - overwriting the shard aggregate and never appearing in
        # the per-stream listing - and every other test here would still pass.
        $ListPrefix = Get-StateBlobStreamPrefix -Prefix 'p/' -Tenant 'T' -ShardIndex 1 -ShardCount 3
        $Stream0 = Get-StateBlobName -Prefix 'p/' -Tenant 'T' -ShardIndex 1 -ShardCount 3 -StreamId 0
        $Unified = Get-StateBlobName -Prefix 'p/' -Tenant 'T' -ShardIndex 1 -ShardCount 3 -StreamId -1

        $Stream0 | Should -Be ('{0}0.json' -f $ListPrefix)
        $Stream0 | Should -Not -Be $Unified -Because 'stream 0 must never collide with the shard aggregate file'
        $Stream0.StartsWith($ListPrefix) | Should -BeTrue -Because 'stream 0 must be discoverable by the per-stream listing'
    }

    It 'does NOT let the shard unified file match the per-stream list prefix' {
        # The unified (StreamId -1) file lives in the same _state/ area. If it
        # matched the per-stream listing prefix, the parent would fold the shard's
        # own aggregate state in as though it were one stream's progress.
        foreach ($Shard in @(@{ I = 0; C = 1 }, @{ I = 1; C = 3 }))
        {
            $ListPrefix = Get-StateBlobStreamPrefix -Prefix 'p/' -Tenant 'T' -ShardIndex $Shard.I -ShardCount $Shard.C
            $Unified = Get-StateBlobName -Prefix 'p/' -Tenant 'T' -ShardIndex $Shard.I -ShardCount $Shard.C -StreamId -1

            $Unified.StartsWith($ListPrefix) | Should -BeFalse -Because 'the shard aggregate file is not a per-stream file'
        }
    }
}

Describe 'Get-StateBlobShardSegment' {

    It 'returns an empty segment for a single-shard run so unsharded paths are unchanged' {
        Get-StateBlobShardSegment -ShardIndex 0 -ShardCount 1 | Should -Be ''
    }

    It 'namespaces by shard whenever more than one shard shares the container' {
        Get-StateBlobShardSegment -ShardIndex 0 -ShardCount 2 | Should -Be 'shard-0of2/'
        Get-StateBlobShardSegment -ShardIndex 2 -ShardCount 3 | Should -Be 'shard-2of3/'
    }

    It 'gives each shard index a DISTINCT segment so two pods cannot collide' {
        # NOT redundant with the prefix-freeness It below, despite appearances. That
        # one does Sort-Object -Unique and then skips equal pairs, so if two different
        # (Index, Count) inputs ever collapsed to the SAME segment, the duplicate would
        # be deduped away, the equal pair would never be compared, and it would pass
        # vacuously. Distinctness has to be asserted separately. Do not delete this.
        $Segments = @(0..4 | ForEach-Object { Get-StateBlobShardSegment -ShardIndex $_ -ShardCount 5 })

        @($Segments | Sort-Object -Unique).Count | Should -Be 5 -Because 'a shared segment would let two shard pods overwrite each other'
    }

    It 'no segment is a string PREFIX of another, even across different shard counts' {
        # Pins that each shard SEGMENT is prefix-free on its own, so a future caller that uses it WITHOUT the '.resume-state-' suffix cannot match another shard's blobs (discovery lists by prefix). It is NOT guarding a current cross-run fold-in - the literal suffix already precludes that.
        # Keep this at SEGMENT level (full-prefix outputs would stop detecting a dropped trailing slash) and EXCLUDE ShardCount 1: its segment is '' (a prefix of everything) yet the unsharded layout is safe, so do not "complete" the matrix by adding it.
        $Segments = @()
        foreach ($Count in @(2, 3, 5, 30, 300))
        {
            # Indices include 10/19/100 so the INDEX-side relation is exercised too
            # (e.g. 'shard-1of300/' vs 'shard-10of300/'). An index-side collision would
            # be a live SAME-RUN collision between two concurrent pods, which is worse
            # than the cross-run case, so it must not go untested.
            foreach ($Index in @(0, 1, 2, 10, 19, 100))
            {
                if ($Index -lt $Count) { $Segments += Get-StateBlobShardSegment -ShardIndex $Index -ShardCount $Count }
            }
        }
        $Segments = @($Segments | Sort-Object -Unique)
        $Segments.Count | Should -BeGreaterThan 10 -Because 'an empty or tiny set would make the loop below pass vacuously'

        foreach ($A in $Segments)
        {
            foreach ($B in $Segments)
            {
                if ($A -eq $B) { continue }
                $B.StartsWith($A) | Should -BeFalse -Because "'$A' must not be a listing prefix of '$B'"
            }
        }
    }
}

Describe 'Get-StateBlobStreamPrefix' {

    It 'honours an empty container-root prefix' {
        Get-StateBlobStreamPrefix -Prefix '' -Tenant 'T' | Should -Be '_state/.resume-state-T-stream-'
    }

    It 'honours a container path prefix and the shard segment together' {
        Get-StateBlobStreamPrefix -Prefix 'team/run5/' -Tenant 'TENANT' -ShardIndex 1 -ShardCount 2 |
            Should -Be 'team/run5/_state/shard-1of2/.resume-state-TENANT-stream-'
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
