# Tests/ScrubContent.Tests.ps1
#
# Test contract for tools/Scrub-Content.ps1, per docs/CONTENT_SAFETY_SPEC.md
# Section 5. Every assertion in the spec must have a corresponding test in
# this file. The drift-detection tests at the bottom of this file fail if
# the spec, the implementation, and these tests get out of sync.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'tools/Scrub-Content.ps1')
    $script:SpecPath = Join-Path $script:RepoRoot 'docs/CONTENT_SAFETY_SPEC.md'
    $script:ToolPath = Join-Path $script:RepoRoot 'tools/Scrub-Content.ps1'
    $script:SpecContent = Get-Content -Path $script:SpecPath -Raw
    $script:ToolContent = Get-Content -Path $script:ToolPath -Raw
}

Describe 'Test-ContentForLeaks: GUIDs' {
    It 'flags real GUIDs' {
        $h = Test-ContentForLeaks -Content 'tenant 1ffec608-964c-4aaa-8f1e-125baacd6ed2'
        # The fixture GUID is allow-listed (test fixture). Use a different real-shape GUID.
        $h = Test-ContentForLeaks -Content 'tenant abcd1234-5678-90ab-cdef-1234567890ab'
        $h.Count | Should -BeGreaterThan 0
        $h[0].Type | Should -Be 'guid'
    }
    It 'flags real GUIDs in mixed/upper case (F1 regression)' {
        # Azure portal URLs and ARM resource IDs commonly use uppercase hex.
        $h = @(Test-ContentForLeaks -Content 'tenant ABCD1234-5678-90AB-CDEF-1234567890AB')
        ($h | Where-Object { $_.Type -eq 'guid' }).Count | Should -BeGreaterThan 0
    }
    It 'does not flag the docs placeholder GUID' {
        $h = Test-ContentForLeaks -Content 'use 12345678-1234-1234-1234-123456789012 as the placeholder'
        ($h | Where-Object { $_.Type -eq 'guid' }).Count | Should -Be 0
    }
    It 'does not flag the empty GUID' {
        $h = Test-ContentForLeaks -Content '00000000-0000-0000-0000-000000000000'
        ($h | Where-Object { $_.Type -eq 'guid' }).Count | Should -Be 0
    }
    It 'does not flag the test-fixture GUID (allow-listed for self-test)' {
        $h = Test-ContentForLeaks -Content 'tenant 1ffec608-964c-4aaa-8f1e-125baacd6ed2'
        ($h | Where-Object { $_.Type -eq 'guid' }).Count | Should -Be 0
    }
    It 'does not flag the test-fixture GUID in uppercase (allow-list is case-insensitive for guids)' {
        $h = Test-ContentForLeaks -Content 'tenant 1FFEC608-964C-4AAA-8F1E-125BAACD6ED2'
        ($h | Where-Object { $_.Type -eq 'guid' }).Count | Should -Be 0
    }
}

Describe 'Test-ContentForLeaks: AWS account IDs' {
    It 'flags AWS account IDs in ARN context' {
        $h = Test-ContentForLeaks -Content 'arn:aws:iam::987654321098:role/Foo'
        ($h | Where-Object { $_.Type -eq 'aws-account' -and $_.Value -eq '987654321098' }).Count | Should -BeGreaterThan 0
    }
    It 'flags AWS account IDs adjacent to letters (F2 regression)' {
        # The old \b regex missed these because \b only fires at \w/\W transitions.
        # The new lookaround pattern requires non-digit on both sides, so digit-letter
        # transitions are still flagged.
        @(
            'arn:aws:iam::987654321098abc/...',
            'something987654321098else',
            '987654321098xyz'
        ) | ForEach-Object {
            $h = @(Test-ContentForLeaks -Content $_)
            ($h | Where-Object { $_.Type -eq 'aws-account' }).Count | Should -BeGreaterThan 0 -Because "should flag '$_'"
        }
    }
    It 'does not flag 14+ digit timestamps' {
        $h = Test-ContentForLeaks -Content 'ResourcesReport_20260521090910142.zip'
        ($h | Where-Object { $_.Type -eq 'aws-account' }).Count | Should -Be 0
    }
    It 'does not flag the docs-placeholder AWS account ID' {
        $h = Test-ContentForLeaks -Content 'arn:aws:s3:::123456789012:bucket'
        ($h | Where-Object { $_.Type -eq 'aws-account' }).Count | Should -Be 0
    }
}

Describe 'Test-ContentForLeaks: internal-Amazon service names' {
    It 'flags internal-Amazon service names case-insensitively' {
        @('CloudRays', 'sentral', 'AWS-CRM', 'midway', 'phonetool') | ForEach-Object {
            $h = Test-ContentForLeaks -Content "use $_"
            ($h | Where-Object { $_.Type -eq 'internal-service' }).Count | Should -BeGreaterThan 0 -Because "should flag $_"
        }
    }
    It 'flags hyphen/underscore/space variants of internal names (F4 regression)' {
        @('cloud-rays', 'cloud_rays', 'cloud rays', 'sen-tral', 'aws_crm', 'mid-way', 'phone_tool') | ForEach-Object {
            $h = @(Test-ContentForLeaks -Content "use $_ today")
            ($h | Where-Object { $_.Type -eq 'internal-service' }).Count | Should -BeGreaterThan 0 -Because "should flag '$_'"
        }
    }
    It 'flags internal hostnames' {
        @('host.amazon-corp.com', 'svc.aws.dev', 'foo.a2z.com') | ForEach-Object {
            $h = Test-ContentForLeaks -Content "see $_"
            ($h | Where-Object { $_.Type -eq 'internal-service' }).Count | Should -BeGreaterThan 0 -Because "should flag $_"
        }
    }
}

Describe 'Test-ContentForLeaks: customer scale fingerprints' {
    It 'flags scale fingerprints' {
        @('125 subscriptions', '17290 resources', '$50,000') | ForEach-Object {
            $h = Test-ContentForLeaks -Content "the customer has $_"
            ($h | Where-Object { $_.Type -eq 'scale-fingerprint' }).Count | Should -BeGreaterThan 0 -Because "should flag $_"
        }
    }
    It 'flags scale fingerprints with thousand separators (F3 regression)' {
        @('1,250 subscriptions', '17,290 resources', '1,000,000 resources', '$1,234') | ForEach-Object {
            $h = @(Test-ContentForLeaks -Content "the customer has $_")
            ($h | Where-Object { $_.Type -eq 'scale-fingerprint' }).Count | Should -BeGreaterThan 0 -Because "should flag '$_'"
        }
    }
    It 'does not flag small subscription counts under 10' {
        $h = Test-ContentForLeaks -Content 'across 2 subscriptions'
        ($h | Where-Object { $_.Type -eq 'scale-fingerprint' }).Count | Should -Be 0
    }
}

Describe 'Test-ContentForLeaks: auth artefacts' {
    It 'flags JWT-shaped tokens' {
        $jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0aaaaaaaaaaaaaaaaaaaaaa.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c'
        $h = Test-ContentForLeaks -Content "Authorization: Bearer $jwt"
        ($h | Where-Object { $_.Type -eq 'auth-token' }).Count | Should -BeGreaterThan 0
    }
    It 'flags JWT split across newlines (F11 regression)' {
        # Real-world line-wrapping in PR descriptions and git diff context lines
        # splits long tokens. The regex uses Singleline so `.` (the literal dot
        # between segments and the regex meta `.`) work even with newlines in
        # the surrounding context. We test by inserting a newline right at one
        # of the JWT segment-separator dots, which is the common case.
        $a = 'eyJ' + ('a' * 30)
        $b = 'b' * 30
        $c = 'c' * 30
        $jwt_with_newline_at_dot = "$a.`n$b.`n$c"
        $h = @(Test-ContentForLeaks -Content $jwt_with_newline_at_dot)
        ($h | Where-Object { $_.Type -eq 'auth-token' }).Count | Should -BeGreaterThan 0
    }
    It 'flags SAS tokens' {
        $sas = 'sv=2024-01-01&ss=b&srt=sco&sp=rwdlacupx&se=2030-01-01T00:00:00Z&sig=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        $h = Test-ContentForLeaks -Content "url=https://x.blob.core.windows.net/?$sas"
        ($h | Where-Object { $_.Type -eq 'auth-token' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Test-CommitMessage: review-process language' {
    It 'flags review-process language in commit messages only' {
        $msg = 'Fix bug. Reviewer said this is out of scope for this PR.'
        $h = Test-CommitMessage -Message $msg
        ($h | Where-Object { $_.Type -eq 'review-process' }).Count | Should -BeGreaterThan 0
    }
    It 'does not flag review-process language via Test-ContentForLeaks (diff scope)' {
        $msg = 'reviewer said something'
        $h = Test-ContentForLeaks -Content $msg
        ($h | Where-Object { $_.Type -eq 'review-process' }).Count | Should -Be 0
    }
}

Describe 'Test-ContentForLeaks: contract guarantees' {
    It 'returns empty (callers wrap with @()) on clean input' {
        $h = @(Test-ContentForLeaks -Content 'hello world this is fine')
        $h.Count | Should -Be 0
    }
    It 'is deterministic across repeated calls' {
        $input = 'arn:aws:iam::987654321098:role/Foo and abcd1234-5678-90ab-cdef-1234567890ab'
        $h1 = @(Test-ContentForLeaks -Content $input)
        $h2 = @(Test-ContentForLeaks -Content $input)
        ($h1 | ConvertTo-Json -Compress) | Should -Be ($h2 | ConvertTo-Json -Compress)
    }
    It 'is idempotent against null/empty input' {
        @(Test-ContentForLeaks -Content '').Count | Should -Be 0
    }
}

# ============================================================================
# Drift-detection tests (Section 6 of the spec)
# ============================================================================

Describe 'Spec drift detection' {
    Context 'spec-implementation drift' {
        It 'every regex pattern in the spec appears in the implementation' {
            # Each pattern is given a literal substring representation in the spec.
            # The implementation must contain the same literal so the two cannot
            # drift. Use .Contains() (literal substring) not -BeLike (wildcard
            # match) because the patterns contain `[` `]` `{` `}` which are
            # wildcard meta-characters in -BeLike.
            #
            # This list intentionally covers EVERY trigger token in the spec.
            # Keep it in sync with docs/CONTENT_SAFETY_SPEC.md Sections 1.1-1.6.
            $expectedSubstrings = @(
                # 1.1 GUID (case-insensitive variants accepted by `IgnoreCase`)
                '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}',
                # 1.2 AWS account
                '(?<![0-9])[0-9]{12}(?![0-9])',
                # 1.3 internal names (each trigger token)
                'cloud[-_ ]?rays',
                'sen[-_ ]?tral',
                'aws[-_ ]?crm',
                'mid[-_ ]?way',
                'aea\b',
                'acme\b',
                'amazon[-_ ]?corp',
                'amazon\.dev',
                'amazon\.work',
                'a2z',
                'phone[-_ ]?tool',
                'quip[-_ ]?amazon',
                # 1.3 internal hosts
                '\.amazon-corp\.com',
                '\.aws\.dev',
                '\.a2z\.com',
                '\.amazon\.work',
                # 1.4 scale
                '\d{2,}(?:,\d{3})*\s+subscriptions',
                'resources',
                # 1.5 auth
                'eyJ[A-Za-z0-9_-]{20,}',
                'sv=\d{4}-\d{2}-\d{2}',
                'Bearer\s+',
                # 1.6 review-process (every trigger)
                'reviewer said',
                'reviewer asked',
                'reviewer flagged',
                'addressed review',
                'address review feedback',
                'deferred to',
                'out of scope for this',
                'low UX',
                'negligible, pre-existing',
                'per the reviewer'
            )
            foreach ($substr in $expectedSubstrings) {
                $script:ToolContent.Contains($substr) | Should -BeTrue -Because "implementation must contain '$substr' from spec"
            }
        }
    }

    Context 'spec-allowlist drift' {
        It 'every allow-list literal in the spec appears in the implementation' {
            $expectedLiterals = @(
                '12345678-1234-1234-1234-123456789012',
                '00000000-0000-0000-0000-000000000000',
                '123456789012',
                '1ffec608-964c-4aaa-8f1e-125baacd6ed2'
            )
            foreach ($lit in $expectedLiterals) {
                $script:ToolContent.Contains($lit) | Should -BeTrue -Because "implementation allow-list must contain '$lit' from spec"
                $script:SpecContent.Contains($lit) | Should -BeTrue -Because "spec allow-list must contain '$lit'"
            }
        }
    }

    Context 'spec-judge-skiplist drift' {
        It 'judge skip-list matches spec Section 3.1' {
            $judgePath = Join-Path $script:RepoRoot 'tools/Validate-Diff.ps1'
            $judgeContent = Get-Content -Path $judgePath -Raw
            $expectedSkipped = @(
                'docs/CONTENT_SAFETY_SPEC.md',
                'tools/Scrub-Content.ps1',
                'tools/Validate-Diff.ps1',
                'tools/README.md',
                'Tests/ScrubContent.Tests.ps1',
                'Tests/ValidateDiff.Tests.ps1'
            )
            foreach ($p in $expectedSkipped) {
                $judgeContent.Contains($p) | Should -BeTrue -Because "judge SkippedFiles must contain '$p' from spec Section 3.1"
                $script:SpecContent.Contains($p) | Should -BeTrue -Because "spec Section 3.1 must list '$p'"
            }
        }
    }

    Context 'spec-test drift' {
        It 'every test name in spec Section 5 appears in this test file' {
            $thisFile = Get-Content -Path $PSCommandPath -Raw
            $expectedTestNames = @(
                'flags real GUIDs',
                'does not flag the docs placeholder GUID',
                'does not flag the empty GUID',
                'flags AWS account IDs in ARN context',
                'does not flag 14+ digit timestamps',
                'flags internal-Amazon service names',
                'flags internal hostnames',
                'flags scale fingerprints',
                'flags JWT-shaped tokens',
                'flags SAS tokens',
                'flags review-process language in commit messages only',
                'returns empty (callers wrap with @()) on clean input',
                'is deterministic across repeated calls'
            )
            foreach ($name in $expectedTestNames) {
                $thisFile.Contains($name) | Should -BeTrue -Because "test '$name' must exist per SPEC Section 5"
            }
        }
    }
}
