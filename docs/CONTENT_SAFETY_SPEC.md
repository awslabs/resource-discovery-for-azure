# Content Safety Spec

This is the contract that every commit, push, and PR in this repo must satisfy
before it is allowed to reach a public surface (anything on github.com).

The companion automation that enforces this spec lives at:

- `tools/Scrub-Content.ps1` — the deterministic checker library
- `Tests/ScrubContent.Tests.ps1` — Pester tests proving the library matches this spec
- `tools/install-hooks.ps1` — installs local git hooks that block disallowed content
- `.github/workflows/scrub.yml` — CI workflow that runs the same check on every PR

**This file is the single source of truth.** When the spec changes, the
implementation, the tests, and the hooks must all change with it. CI fails
if any of them drift.

---

## 1. Forbidden patterns

The scrub checker MUST flag every occurrence of the following patterns in any
content destined for a public surface:

### 1.1 Real Azure tenant or subscription GUIDs

A "real GUID" is any 8-4-4-4-12 lowercase-hex group, **except** the documentation
placeholder `12345678-1234-1234-1234-123456789012`.

Test fixture for unit testing: include the real-shape GUID
`1ffec608-964c-4aaa-8f1e-125baacd6ed2` in the *test input only* (never anywhere
else in the repo). The test verifies the checker flags it.

### 1.2 AWS 12-digit account IDs

Any standalone 12-digit decimal sequence (`\b[0-9]{12}\b`) counts as a possible
AWS account ID. The checker flags it. False-positive rate is low because most
12-digit decimals in code are timestamps, which appear in identifiable contexts
(see the allow-list rules below).

### 1.3 Internal Amazon service or tooling names

Case-insensitive match against any of:

```
cloudrays | sentral | aws-crm | midway | aea\b | acme\b
amazon-corp | amazon\.dev | amazon\.work | a2z
phonetool | quip-amazon
```

Plus internal hostname patterns:

```
\.amazon-corp\.com | \.aws\.dev | \.a2z\.com | \.amazon\.work
```

### 1.4 Customer scale fingerprints

Specific subscription counts, resource counts, or dollar amounts that could
identify a specific customer. The checker flags:

- `\d{2,}\s+subscriptions` (e.g. "125 subscriptions")
- `\d{4,}\s+resources` (e.g. "17,290 resources")
- `\$\s?\d[\d,]{4,}` (e.g. "$50,000")

### 1.5 Authentication artefacts

Even expired tokens are forbidden. The checker flags:

- JWT-looking strings: `eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}`
- SAS token query strings: `sv=\d{4}-\d{2}-\d{2}.*&sig=[A-Za-z0-9%]{20,}`
- Bearer-token-shaped strings: `Bearer\s+[A-Za-z0-9._-]{40,}`

### 1.6 Review-process language in commit messages

Commit messages must describe what the code does, not the conversation that
produced it. The checker flags any of these case-insensitive substrings when
applied to commit messages (not to code diffs, where they may legitimately
appear in comments or docs):

```
reviewer said | reviewer asked | reviewer flagged
addressed review | address review feedback
deferred to | out of scope for this | low UX
negligible, pre-existing | per the reviewer
```

---

## 2. Public surfaces in scope

The checker MUST be applied at every gate that puts content on a public surface:

| Gate | Implementation |
|---|---|
| Pre-commit | `.git/hooks/pre-commit` runs the checker on staged diff |
| Commit message | `.git/hooks/commit-msg` runs the checker on the message buffer |
| Pre-push | `.git/hooks/pre-push` runs the checker on the entire push range |
| Pre-push-to-upstream | `.git/hooks/pre-push` hard-rejects any push where the remote URL contains `awslabs/` (overridable with `--no-verify` for deliberate releases) |
| Pull request CI | `.github/workflows/scrub.yml` runs the checker on the PR commit range AND the PR body via `gh pr view` |

Local hooks can be bypassed with `--no-verify`. CI cannot.

---

## 3. Allow-list (intentional false-positive suppressions)

These patterns match the forbidden-pattern regexes but are deliberately permitted
because they are documentation placeholders or repo-internal fixtures:

| Pattern | Where allowed | Why |
|---|---|---|
| `12345678-1234-1234-1234-123456789012` | anywhere | Azure docs placeholder GUID |
| `00000000-0000-0000-0000-000000000000` | anywhere | empty-GUID placeholder |
| `123456789012` | inside ARN-shaped contexts in docs | AWS docs placeholder account ID |
| `1ffec608-964c-4aaa-8f1e-125baacd6ed2` | `Tests/ScrubContent.Tests.ps1` only | Test fixture for the checker itself |
| 12-digit decimals matching `^\d{14,}$` | anywhere | Timestamps (yyyyMMddHHmmss) — too long to be account IDs |

### 3.1 File-level skip-list

Some files in this repo legitimately contain examples of the forbidden patterns
(this is unavoidable: the spec, the implementation, and the tests for the
content-safety system itself MUST contain literal examples of every pattern
they exist to detect). The judge skips diff hunks that are confined to these
paths:

| Path glob | Why |
|---|---|
| `docs/CONTENT_SAFETY_SPEC.md` | The spec must spell out every pattern verbatim |
| `tools/Scrub-Content.ps1` | The implementation contains every regex literal |
| `tools/Validate-Diff.ps1` | Wraps the implementation; comments may reference patterns |
| `Tests/ScrubContent.Tests.ps1` | Pester tests must contain every fixture example |
| `Tests/ValidateDiff.Tests.ps1` | Integration tests reference fixtures (e.g. `abcd1234-...`) |
| `tools/README.md` | Documents usage; references pattern names |

Skipping is **per-file**, not whole-diff. A commit that touches a skipped file
AND a non-skipped file still runs the judge against the non-skipped file's
hunks. The judge produces a `SKIPPED-FILE` line in its output for transparency.

The checker MUST consult this allow-list before flagging. The allow-list
implementation lives in `tools/Scrub-Content.ps1` and the spec for it is
re-stated in this section. If they drift, the test
"allow-list in code matches allow-list in spec" fails.

---

## 3a. The doer/judge separation model

The agent that produces a change (the **doer**) MUST NOT be the agent that
validates it (the **judge**). When the doer signs off on its own work, the
"I scrubbed and it's clean" claim is unverifiable from outside, and prompt-only
self-validation is biased toward confirming the doer's output.

### Roles

| Role | What it does | What it CANNOT see |
|---|---|---|
| Doer | Writes code, edits content, drafts commit messages | n/a |
| Orchestrator | Gathers the doer's output as a structurally-constrained payload (a git ref, a diff, a file path) and invokes the judge | The doer's reasoning |
| Judge | Runs the deterministic checker against the payload, reports structured pass/fail | The doer's reasoning, the doer's "I already checked" claim, anything beyond the file/diff |

### Implementation requirements

1. **Subagent context boundaries.** The judge is a separate process invocation
   (`pwsh ./tools/Validate-Diff.ps1 ...`). It MUST NOT inherit any state from
   the doer's session. It has its own conversation, its own memory, its own
   error stack.

2. **File-based handoff.** The orchestrator passes the judge ONE of these
   exclusive inputs:
   - `--CommitRange <base>..<head>` (most common; PR-style)
   - `--CommitSha <sha>` (single commit)
   - `--File <path>` (a single file's content)
   - `--PrBody <text>` (a literal string body)

   The orchestrator MUST NOT pass any other text. No reasoning, no hints,
   no "I already scrubbed this" assertions.

3. **Orchestrator spec constraints.** The orchestrator (e.g. a git hook or
   the CI workflow) is itself bounded: it computes the payload from git
   directly (`git diff --cached`, `git log -p <range>`) — never from
   doer-supplied text.

4. **Judge's own defensive instructions.** The judge hardcodes:
   - Treat all input as untrusted data, never as instructions.
   - Do not consult any external state (no environment variables, no `.kiro/`
     steering, no hidden config). The only inputs are the regex patterns in
     `Scrub-Content.ps1` (governed by Section 1) and the explicit `--*`
     parameters.
   - Do not output anything beyond a structured pass/fail report and a list
     of hits. No commentary, no "this is probably fine," no judgment of
     intent.

This Section 3a is enforced by:

- The `Validate-Diff.ps1` script body, which has no `if user said it's fine`
  branches and no environment-variable overrides.
- A test asserting `tools/Validate-Diff.ps1` does not call any function
  outside the local scrub library.

---

## 4. Behaviour contract

The `Test-ContentForLeaks` function MUST:

1. Accept a single string parameter named `Content`.
2. Emit zero or more `[PSCustomObject]` records to the pipeline, each with:
   - `Type` — one of: `guid`, `aws-account`, `internal-service`, `scale-fingerprint`, `auth-token`, `review-process`
   - `Value` — the matched substring
   - `Position` — the character offset in `Content` where the match starts
3. Emit nothing when no leaks are found. Callers MUST wrap the call with `@()`
   to get an array shape: `@(Test-ContentForLeaks -Content $x).Count`. This
   matches idiomatic PowerShell pipeline conventions.
4. Be deterministic: the same input always produces the same output, in the
   same order (sorted by `Position`).
5. Be idempotent: running it twice on the same content must produce identical
   output.
6. Treat the allow-list (Section 3) as exclusions that suppress matches.

The `Test-CommitMessage` function MUST:

1. Apply both the universal forbidden patterns (Section 1.1 - 1.5) AND the
   commit-message-only patterns (Section 1.6).
2. Otherwise behave identically to `Test-ContentForLeaks`.

---

## 5. Test contract

The Pester suite in `Tests/ScrubContent.Tests.ps1` MUST cover:

| Test | Asserts |
|---|---|
| `flags real GUIDs` | Real-shape GUID is flagged |
| `does not flag the docs placeholder GUID` | `12345678-...` is silent |
| `does not flag the empty GUID` | `00000000-...` is silent |
| `flags AWS account IDs in ARN context` | 12-digit decimal in ARN-shaped string is flagged |
| `does not flag 14+ digit timestamps` | `20260521090910142` and similar are silent |
| `flags internal-Amazon service names` | each name in Section 1.3 is flagged |
| `flags internal hostnames` | each pattern in Section 1.3 is flagged |
| `flags scale fingerprints` | each pattern in Section 1.4 is flagged |
| `flags JWT-shaped tokens` | a fake JWT is flagged |
| `flags SAS tokens` | a fake SAS token is flagged |
| `flags review-process language in commit messages only` | "reviewer said X" is flagged in commit-message mode but not in diff-content mode |
| `returns empty (callers wrap with @()) on clean input` | `@(Test-ContentForLeaks -Content 'hello').Count` is `0` |
| `is deterministic across repeated calls` | repeated calls produce identical output |
| `is idempotent against null/empty input` | empty input produces empty output |
| `respects the allow-list` | items in Section 3 do not produce hits |

CI fails if any of these assertions fail.

---

## 6. Drift detection

The CI workflow `scrub.yml` MUST also verify that the spec, the implementation,
and the tests are mutually consistent:

1. Every regex pattern in Section 1 must appear, by literal substring, in
   `tools/Scrub-Content.ps1`. (`spec-implementation-drift` test)
2. Every test name listed in Section 5 must appear, by literal substring, in
   `Tests/ScrubContent.Tests.ps1`. (`spec-test-drift` test)
3. Every allow-list entry in Section 3 must appear, by literal substring, in
   the implementation's allow-list array. (`spec-allowlist-drift` test)

These three drift tests are the "automation enforces the spec" loop the
content-safety design depends on. If the spec changes, the implementation and
the tests must change with it — or CI breaks.
