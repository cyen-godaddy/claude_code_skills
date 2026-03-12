# PR Comment Resolver Improvements Design

**Date:** 2026-03-12
**Status:** Draft
**Scope:** GitHub-only, production-grade robustness

## Overview

Improve the pr-comment-resolver skill to be production-grade with robust API handling, edge case coverage, and accurate parsing. Extract complex operations to testable scripts while keeping decision logic in SKILL.md.

## Goals

- Handle pagination, rate limits, and network failures gracefully
- Support GitHub suggestion blocks with explicit code proposals
- Handle edge cases: deleted files, outdated diffs, merge conflicts, binary files
- Require explicit user permission before commits and resolves
- Provide consistent output via templates

## File Structure

```
pr-comment-resolver/
├── SKILL.md                    # Orchestration + decision logic
├── scripts/
│   ├── fetch-unresolved.sh     # Fetch all unresolved comments (paginated)
│   └── verify-and-resolve.sh   # Verify fix exists, reply, resolve thread
└── assets/
    ├── commit-message.tpl      # Template for commit message
    └── reply.tpl               # Template for comment reply
```

## Scripts

### fetch-unresolved.sh

Fetches all unresolved PR comments with pagination, retries, and clean JSON output.

**Interface:**
```bash
./fetch-unresolved.sh <owner> <repo> <pr_number>
# Outputs JSON to stdout, errors to stderr
# Exit codes: 0=success, 1=auth error, 2=not found, 3=rate limited
```

**Robustness features:**
- Pagination: Loop through all reviewThreads (not just first 50)
- Retries: 3 attempts with exponential backoff for transient failures
- Rate limiting: Detect 403/rate limit responses, wait and retry
- All comments: Fetch all comments per thread for conversation context
- Clean output: Structured JSON with normalized fields

**Output format:**
```json
[
  {
    "threadId": "PRT_xxx",
    "commentId": 12345,
    "path": "src/foo.js",
    "line": 42,
    "side": "RIGHT",
    "body": "Consider adding null check",
    "author": "reviewer-name",
    "outdated": false,
    "hasSuggestion": true,
    "suggestionCode": "if (x != null) { ... }",
    "suggestionStartLine": 42,
    "suggestionEndLine": 42,
    "originalCode": "if (x) { ... }",
    "replies": [...]
  }
]
```

**Edge cases flagged in output:**
- Comments on deleted files: `path` marked as missing
- Outdated comments: `outdated: true`
- Suggestion blocks: Parsed to `suggestionCode`, `suggestionStartLine`, `suggestionEndLine`, `originalCode`

### verify-and-resolve.sh

Verifies a fix exists in the file, then posts reply and resolves thread — only after user confirms.

**Interface:**
```bash
./verify-and-resolve.sh <owner> <repo> <thread_id> <comment_id> <file_path> <search_pattern> <reply_message> [--dry-run]
# Exit codes: 0=resolved, 1=verification failed, 2=API error, 3=already resolved
```

**Workflow:**
1. Check if thread already resolved → exit 3 if yes
2. Verify file contains expected pattern → exit 1 if not found
3. Post reply comment → exit 2 if fails
4. Resolve thread via GraphQL mutation → exit 2 if fails
5. Confirm resolution → exit 0

**Safety guards:**
- `--dry-run` is the default when called from SKILL.md
- Never resolves without verification passing
- Logs all actions to stderr for audit trail
- Fails closed (any uncertainty = don't resolve)

**Retry strategy:**
- Attempt 1: Immediate
- Attempt 2: Wait 2 seconds
- Attempt 3: Wait 5 seconds
- Then fail with appropriate exit code

## Assets/Templates

### assets/commit-message.tpl

```
fix: address PR review comments

Applied {applied_count} changes from PR #{pr_number}:
{changes_list}

Skipped {skipped_count} comments (see PR for details)
```

### assets/reply.tpl

```
Fixed — {description}

<!-- Applied by pr-comment-resolver -->
```

**Template variables:**

| Variable | Source |
|----------|--------|
| `{applied_count}` | Count of successfully applied fixes |
| `{skipped_count}` | Count of skipped comments |
| `{pr_number}` | From input |
| `{changes_list}` | Bullet list of file:line — description |
| `{description}` | Brief description of what was fixed |

## Suggestion Block Handling

GitHub suggestions use a special markdown format:

````markdown
```suggestion
const result = value ?? defaultValue;
```
````

**Three comment types with different handling:**

| Type | Example | Handling |
|------|---------|----------|
| Suggestion block | Exact code in \`\`\`suggestion\`\`\` | Apply directly — reviewer's intent is explicit |
| Interpretive comment | "Consider adding null check" | Claude analyzes and writes the fix |
| Question/discussion | "Why did you choose X?" | Skip — not actionable |

**Suggestion block logic:**
1. Extract the suggested code
2. Identify the target lines (GitHub provides line range)
3. Check if target lines still match original code
   - Match: Apply suggestion directly (replace lines)
   - Mismatch: Flag as "outdated suggestion — code has changed"
4. Track as "applied (suggestion)" vs "applied (interpreted)"

## Updated SKILL.md Structure

### Phase 1: Fetch Comments
Run `./scripts/fetch-unresolved.sh <owner> <repo> <pr>`
- Script handles pagination, retries, rate limits
- Outputs JSON array of unresolved comments

### Phase 2: Analyze & Apply (LOCAL ONLY)
For each comment in JSON output:

**Decision tree:**
1. Is it a suggestion block?
   - Yes + code matches → Apply directly
   - Yes + code mismatched → Flag "outdated suggestion"
2. Is it an interpretive comment?
   - Read target file, understand intent
   - Applies? → Edit file, track change
   - Unclear/wrong? → Flag with reason
3. Is it a question/discussion?
   - Skip — not actionable

**Apply criteria:**
- Corrects an actual bug or inconsistency
- Aligns with project conventions
- Localized fix that won't break other code

**Skip criteria:**
- Misunderstands the code's intent
- Would introduce a bug
- Ambiguous or contradictory
- Lack context to be confident

### Phase 3: Report Results
Output summary:
```
## PR Comment Resolution Summary

**Applied (suggestion):** N changes
**Applied (interpreted):** M changes
**Skipped:** K comments

### Applied Changes
- `src/foo.js:42` — [suggestion] Replaced || with ??
- `src/bar.js:18` — [interpreted] Added null check

### Skipped (Needs Review)
- `config.js:42` — Conflicts with existing error handling
- `api.ts:18` — Question, not actionable
```

### Phase 4: User Permission Gate

```
<HARD-GATE>
ASK: "Commit, push, and resolve N comments? [y/N]"
STOP and wait for explicit "yes" before proceeding.
Never commit or resolve without user permission.
</HARD-GATE>
```

### Phase 5: Commit, Push, Resolve
Only after user confirms:
1. Stage and commit using assets/commit-message.tpl
2. Push to remote
3. For each applied fix:
   - Run verify-and-resolve.sh (without --dry-run)
   - Report success/failure per thread

## Error Handling

### Script Exit Codes

| Script | Exit | Meaning | Action |
|--------|------|---------|--------|
| fetch-unresolved.sh | 0 | Success | Continue |
| | 1 | Auth error | Stop: "Run `gh auth login`" |
| | 2 | PR not found | Stop: "Check URL format" |
| | 3 | Rate limited after retries | Stop: "GitHub rate limit, try in 15 min" |
| verify-and-resolve.sh | 0 | Resolved | Report success |
| | 1 | Verification failed | Report "Fix not found in file — NOT resolved" |
| | 2 | API error | Report "Failed to resolve — manual action needed" |
| | 3 | Already resolved | Skip silently |

### Edge Cases

| Edge Case | Detection | Handling |
|-----------|-----------|----------|
| Comment on deleted file | `path` not in local repo | Skip: "File deleted — cannot apply" |
| Outdated suggestion | Original code doesn't match | Skip: "Code changed since suggestion" |
| Binary file | File extension or content check | Skip: "Binary file — manual review needed" |
| Merge conflict markers | `<<<<<<<` in target file | Stop Phase 2: "Resolve merge conflicts first" |
| Not on PR branch | Compare `git branch` with PR head | Warn: "Not on PR branch — changes may not match" |
| Empty PR (no comments) | JSON output is `[]` | Exit: "No unresolved comments found" |
| Comment spans deleted lines | Line number > file length | Skip: "Target line no longer exists" |

## Implementation Notes

- Scripts should be POSIX-compliant where possible for portability
- All scripts use `set -euo pipefail` for strict error handling
- GraphQL queries use `gh api graphql` for authentication
- JSON parsing uses `jq` (document as prerequisite)

## Out of Scope

- GitLab, Bitbucket, Azure DevOps support
- Automatic resolution without user confirmation
- Modifying comments (only replying and resolving)
