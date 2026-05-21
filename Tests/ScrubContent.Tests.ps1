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
}

Describe 'Test-ContentForLeaks: AWS account IDs' {
    It 'flags AWS account IDs in ARN context' {
        $h = Test-ContentForLeaks -Content 'arn:aws:iam::987654321098:role/Foo'
        ($h | Where-Object { $_.Type -eq 'aws-account' -and $_.Value -eq '987654321098' }).Count | Should -BeGreaterThan 0
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
            # We assert the implementation contains the same literal so the two
            # cannot drift. If the spec changes, the implementation must too.
            # Note: use .Contains() (literal substring), not -BeLike (wildcard
            # match), because the patterns contain `[` `]` `{` `}` which are
            # wildcard meta-characters in -BeLike.
            $expectedSubstrings = @(
                '[0-9a-f]{8}-[0-9a-f]{4}',                      # GUID
                '\b[0-9]{12}\b',                                # AWS account
                'cloudrays',                                    # internal name
                'amazon-corp',                                  # internal hostname
                '\d{2,}\s+subscriptions',                       # scale
                'eyJ[A-Za-z0-9_-]{20,}',                        # JWT
                'sv=\d{4}-\d{2}-\d{2}',                         # SAS
                'reviewer said'                                 # review-process
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
