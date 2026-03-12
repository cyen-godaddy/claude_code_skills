---
name: pr-comment-resolver
description: Use when addressing GitHub PR review comments, resolving Copilot suggestions, fixing code review feedback, or applying reviewer suggestions in bulk. Triggers on PR URLs, "resolve comments", "address feedback", "fix review comments".
license: Proprietary
metadata:
  author: godaddy-platform
  version: "2.0"
  category: developer-tools
---

# PR Comment Resolver

Analyze and apply GitHub PR review comments locally, flagging suggestions that don't make sense.

## When to Use

- Addressing code review feedback on a PR
- Resolving Copilot automated suggestions
- Fixing multiple PR comments in bulk
- Applying reviewer suggestions after code review

## The Iron Law

```
ANALYZE BEFORE APPLYING. FLAG WHAT DOESN'T MAKE SENSE. NEVER COMMIT OR RESOLVE WITHOUT USER PERMISSION.
```

## Prerequisites

- `gh` CLI installed and authenticated (`gh auth status`)
- `jq` installed for JSON processing
- Local clone of the repository
- Ideally on the PR branch (`gh pr checkout NUMBER`)

## Input Formats

Accept PR URLs in any format:
- `https://github.com/owner/repo/pull/123`
- `owner/repo#123`
- Just `123` if already in the repo

## Execution

### Phase 1: Fetch Unresolved Comments

```bash
# Extract owner/repo/number from URL, then run:
./scripts/fetch-unresolved.sh <owner> <repo> <pr_number>
```

Script handles:
- Pagination (fetches all threads, not just first 50)
- Retries with exponential backoff for transient failures
- Rate limit detection and waiting
- Suggestion block parsing

Output: JSON array of unresolved comments with fields:
- `threadId`, `commentId`, `path`, `line`, `body`, `author`
- `outdated` (boolean) — thread marked outdated by GitHub
- `hasSuggestion` (boolean), `suggestionCode` (string|null)
- `suggestionStartLine`, `suggestionEndLine` — line range for suggestions
- `originalCode` — code context from diff hunk for outdated detection

### Phase 2: Analyze & Apply (LOCAL ONLY)

For each comment in JSON output:

**Decision Tree:**

```
1. Is it a suggestion block? (hasSuggestion: true)
   ├─ If suggestionCode is null → Treat as interpretive (parse failed, likely CRLF)
   ├─ If outdated: true → Flag "GitHub marked stale"
   └─ Does file at path:line contain originalCode?
       ├─ Yes → Apply suggestionCode directly (replace lines)
       └─ No → Flag "outdated suggestion — code has changed"

2. Is it an interpretive comment?
   ├─ Read target file, understand intent
   ├─ Makes sense? → Edit file using Edit tool, track change
   └─ Unclear/wrong? → Flag with reason

3. Is it a question/discussion?
   └─ Skip — not actionable
```

**Apply when:**
- Corrects an actual bug or inconsistency
- Aligns with project conventions
- Localized fix that won't break other code
- Suggestion block with matching target code

**Flag and skip when:**
- Misunderstands the code's intent
- Would introduce a bug
- Ambiguous or contradictory
- Insufficient context to apply confidently
- Outdated suggestion (code has changed)
- Question or discussion (not actionable)

### Phase 3: Report Results

Output during processing:
```
✓ file.js:55 — [suggestion] Applied null coalescing operator
✓ config.ts:42 — [interpreted] Added error handling
⊘ api.ts:18 — SKIPPED: Question, not actionable
⊘ utils.js:30 — SKIPPED: Outdated suggestion — code has changed
```

Summary report:
```
## PR Comment Resolution Summary

**Applied (suggestion):** N changes
**Applied (interpreted):** M changes
**Skipped:** K comments

### Applied Changes
- `file.js:55` — [suggestion] Replaced || with ??
- `config.ts:42` — [interpreted] Added null check before access

### Skipped (Needs Review)
- `api.ts:18` — Question, not actionable
- `utils.js:30` — Outdated suggestion — code has changed

### Next Steps
Would you like me to commit, push, and resolve the applied comments?
```

### Phase 4: User Permission Gate

<HARD-GATE>
ASK: "Commit, push, and resolve N comments? [y/N]"
STOP and wait for explicit "yes" before proceeding.
NEVER commit changes or resolve threads without user permission.
</HARD-GATE>

### Phase 5: Verify, Commit, Push, Resolve

Only after user confirms:

**Step 1: Commit changes**
```bash
# Stage ONLY the files that were edited during Phase 2 (avoid git add -A)
# Use the tracked list of applied changes to stage specific files
git add <list-of-modified-files> && git commit -m "fix: address PR review comments

Applied N changes from PR #123:
- file.js:55 — [suggestion] Replaced || with ??
- config.ts:42 — [interpreted] Added null check

Skipped M comments (see PR for details)"
```

**Step 2: Push**
```bash
git push
```

**Step 3: Verify and resolve each applied fix**

For each applied change, verify BEFORE resolving:
```bash
./scripts/verify-and-resolve.sh <owner> <repo> <thread_id> <file_path> "<search_pattern>" "<reply_message>"
```

The `<search_pattern>` should be a **plain literal substring** from the applied change (no shell escaping of brackets, quotes, etc.). For example, if the fix added `allowed_methods=["GET"]`, pass exactly that string — `grep -F` matches literally.

For outdated threads already fixed in prior commits, use `--skip-verify`:
```bash
./scripts/verify-and-resolve.sh <owner> <repo> <thread_id> - - "<reply_message>" --skip-verify
```

Output verification results:
```
Verifying fixes in files...
✓ file.js:55 — VERIFIED: Pattern found, thread resolved
✓ config.ts:42 — VERIFIED: Pattern found, thread resolved
✗ api.ts:30 — NOT FOUND: Fix not in file, thread NOT resolved
⊘ helpers.py — SKIPPED verification (outdated, --skip-verify), thread resolved
```

**CRITICAL:** Only resolve comments whose fixes are verified present in the pushed code (or confirmed fixed via `--skip-verify` for outdated threads).

## Error Handling

| Exit Code | Script | Meaning | Action |
|-----------|--------|---------|--------|
| 0 | fetch-unresolved.sh | Success | Continue |
| 1 | fetch-unresolved.sh | Auth error | Stop: "Run `gh auth login`" |
| 2 | fetch-unresolved.sh | PR not found or API error | Stop: "Verify PR URL; if correct, retry (may be transient)" |
| 3 | fetch-unresolved.sh | Rate limited | Stop: "GitHub rate limit, try in 15 min" |
| 0 | verify-and-resolve.sh | Resolved | Report success |
| 1 | verify-and-resolve.sh | Verification failed | Report "Fix not found — NOT resolved" |
| 2 | verify-and-resolve.sh | API error | Report "Failed to resolve — manual action needed" |
| 3 | verify-and-resolve.sh | Already resolved | Skip silently |

## Edge Cases

| Edge Case | Detection | Handling |
|-----------|-----------|----------|
| Comment on deleted file | `path` not in local repo | Skip: "File deleted — cannot apply" |
| Outdated suggestion | `originalCode` not in file at line | Skip: "Code changed since suggestion" |
| Binary file | File extension check | Skip: "Binary file — manual review needed" |
| Merge conflict markers | `<<<<<<<` in target file | Stop: "Resolve merge conflicts first" |
| Not on PR branch | Compare with PR head | Warn: "Not on PR branch — changes may not match" |
| Empty PR | JSON output is `[]` | Exit: "No unresolved comments found" |
| Deleted lines | Line number > file length | Skip: "Target line no longer exists" |

## Related Skills

- `darc-review` — Reviews API spec PRs (complementary workflow)
