---
name: pr-comment-resolver
description: Use when addressing GitHub PR review comments, resolving Copilot suggestions, fixing code review feedback, or applying reviewer suggestions in bulk. Triggers on PR URLs, "resolve comments", "address feedback", "fix review comments".
license: Proprietary
metadata:
  author: godaddy-platform
  version: "2.3"
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
READ AT LEAST 20 LINES OF CONTEXT AROUND EACH TARGET LINE BEFORE DECIDING TO APPLY OR SKIP.
```

## Prerequisites

- `gh` CLI installed and authenticated (`gh auth status`)
- `jq` installed for JSON processing
- Local clone of the repository
- On the PR branch — Phase 0 verifies this and auto-switches if needed

## Input Formats

Accept PR URLs in any format:
- `https://github.com/owner/repo/pull/123`
- `owner/repo#123`
- Just `123` if already in the repo

## Execution

### Phase 0: Verify Branch

Before doing anything else, confirm the working directory is on the PR's head branch.

```bash
# Get the PR's head branch name
pr_branch=$(gh pr view <pr_number> --repo <owner>/<repo> --json headRefName --jq '.headRefName')

# Get the current local branch
current_branch=$(git branch --show-current)
```

**Decision:**
- `current_branch == pr_branch` → Continue to freshness check below
- `current_branch != pr_branch` → Switch automatically with `gh pr checkout <pr_number>`, then confirm the switch succeeded before continuing. If the checkout fails (e.g., uncommitted changes), ask the user to resolve it.

**NEVER skip this check.** Applying fixes on the wrong branch means the push will go to the wrong place and verify-and-resolve.sh will resolve threads against code that isn't in the PR.

**Freshness check — ensure local branch is up-to-date:**

```bash
git fetch origin "$pr_branch"
git status
```

- If local is behind remote → run `git pull --ff-only`. If that fails (diverged history), ask the user to resolve it.
- If local is up-to-date → Proceed to Phase 1.

### Phase 1: Fetch Unresolved Comments

```bash
# Extract owner/repo/number from URL, then run:
./scripts/fetch-unresolved.sh <owner> <repo> <pr_number>
```

Script handles:
- Pagination (fetches all threads, not just first 50)
- Retries with stepped backoff (0s, 2s, 5s) for transient failures
- Rate limit detection (via gh exit codes + GraphQL error types) and retry
- Suggestion block parsing (including `suggestionRange` for extended syntax)
- PR-level comment warning (comments without `path` are logged but excluded from output)

Pass `--verbose` to enable debug logging (API calls, retry attempts, transforms).

Output: JSON array of unresolved comments with fields:
- `threadId`, `path`, `line`, `body`, `author` — core fields used by verify-and-resolve.sh
- `commentId` — included for reference/logging but not required by verify-and-resolve.sh
- `startLine` — start of the comment's line range (null if single-line)
- `side` — diff side: `"RIGHT"` (PR head) or `"LEFT"` (base)
- `outdated` (boolean) — thread marked outdated by GitHub
- `hasSuggestion` (boolean), `suggestionCode` (string|null)
- `suggestionRange` (string|null) — range modifier from ` ```suggestion:-0+3 ` syntax (e.g., `"-0+3"`, `":0-3"`), null for plain ` ```suggestion `
- `suggestionStartLine`, `suggestionEndLine` — line range for suggestions
- `originalCode` — code context from diff hunk (RIGHT side for PR head, LEFT side for base)
- `replies` — array of reply comment bodies (for conversation context)

### Phase 2: Analyze & Apply (LOCAL ONLY)

**"LOCAL ONLY" means:** Edit files using your editor tools only. Do NOT call verify-and-resolve.sh, git commit, git push, or any GitHub API during this phase.

**State tracking:** Maintain a list of all comments with their resolution. For each comment, track: `{path, line, threadId, type, description, status}` where type is `suggestion | interpreted | skipped | general` and status is `applied | skipped | flagged`. You will need this list in Phase 3 (report) and Phase 5 (resolve).

**Processing Order:**

1. Separate PR-level comments (`path` is null) → set aside as "General Comments"
2. Separate file-level comments (`path` present, `line` is null) → set aside as "File-level Comments" (flag for review, not auto-applicable)
3. Group remaining comments by file path
4. Within each file, sort by line number **descending** (primary key — bottom-up editing preserves line numbers for subsequent edits)
5. At the same line, process suggestions before interpretive comments (secondary key)

**Decision Tree (evaluate each comment in processing order):**

```
0. Check replies array FIRST
   ├─ Author wrote "never mind", "ignore", "withdrawn" → Skip
   ├─ Follow-up clarifies intent → Use clarification to inform steps below
   └─ Reviewers disagree in replies → Flag for human review, do not apply

1. Is side == "LEFT"? (comment on base version, not PR head)
   └─ Flag: "LEFT-side comment — targets base version, not current code. Manual review needed."

2. Is it a suggestion block? (hasSuggestion: true)
   ├─ If suggestionCode is null → Treat as interpretive (parse failed, likely CRLF)
   ├─ If outdated: true → Still check originalCode (see below); outdated flag alone is not conclusive
   └─ Does originalCode appear in the file near path:line? (see Comparing originalCode below)
       ├─ Yes → Apply suggestionCode directly (replace lines per Line Range Mechanics)
       └─ No → Flag "outdated suggestion — code has changed since review"

3. Is it an interpretive comment? (see Classifying Comments below)
   ├─ Read at least 20 lines of context around the target line
   ├─ Makes sense? → Edit file using Edit tool, track change
   └─ Unclear/wrong? → Flag with reason

4. Is it a question/discussion?
   └─ Skip — not actionable
```

**Classifying Comments — Interpretive vs Question:**

| Signal | Classification |
|---|---|
| Contains imperative verb ("use", "add", "remove", "rename", "change to") | Interpretive |
| References a specific code change ("replace X with Y", "should be const") | Interpretive |
| Phrased as open question with no concrete alternative ("Why is this here?") | Question |
| Asks for explanation ("Can you explain...?", "What does this do?") | Question |
| Implicit suggestion phrased as question ("Why not use a Map here?") | Interpretive — treat the implied suggestion as the intent |

When ambiguous, flag rather than guess.

**Comparing `originalCode` to Current File:**

`originalCode` is extracted from the diff hunk and may include surrounding context lines beyond the exact target. To compare:

1. Read the file content around `line` (±5 lines to account for minor line shifts)
2. Check if `originalCode` appears as a substring in that region (after trimming leading/trailing blank lines from both)
3. If it matches → the code is still in place, safe to apply
4. If no match → the code has changed since the review; flag as outdated

Do NOT require exact line-number alignment — small shifts from other edits are expected.

**Overlapping Comment Conflict Resolution:**

When multiple comments target overlapping `[startLine, line]` ranges in the same file:
1. Apply the first (bottom-most) edit normally
2. Before applying the next overlapping edit, re-read the file and verify `originalCode` still matches
3. If `originalCode` no longer matches (displaced by prior edit), flag the conflict rather than silently applying

**Applying Suggestions — Line Range Mechanics:**

When `hasSuggestion` is true, determine the replacement range:

| `suggestionRange` | `startLine` | Replacement Range |
|---|---|---|
| null | null | Replace single `line` with `suggestionCode` |
| null | present | Replace `startLine` through `line` (inclusive) |
| present (e.g., `"-2+5"`) | — | Parse as `-offset+span`: start at `line - offset`, replace `span` lines |

**Worked example:** `line=10`, `suggestionRange="-2+5"` → start at line `10 - 2 = 8`, replace 5 lines (lines 8 through 12 inclusive) with `suggestionCode`.

If `suggestionCode` contains more lines than the replaced range, the extra lines are inserted (the file grows). If fewer, the file shrinks. This is normal.

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
- Code has changed since review (`originalCode` mismatch)
- LEFT-side comment (targets base, not HEAD)
- Question or discussion (not actionable)
- Author withdrew the comment in replies

### Phase 3: Report Results

Output during processing:
```
✓ file.js:55 — [suggestion] Applied null coalescing operator
✓ config.ts:42 — [interpreted] Added error handling
⊘ api.ts:18 — SKIPPED: Question, not actionable
⊘ utils.js:30 — SKIPPED: Outdated suggestion — code has changed
ℹ (PR-level) — General comment: "Consider adding integration tests"
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

### General Comments (PR-level, no file target)
- "Consider adding integration tests" — @reviewer

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
# Stage ONLY the files from your Phase 2 state tracking list (avoid git add -A)
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

The `<search_pattern>` should be a **plain literal substring** from the NEW code you wrote or the `suggestionCode` you applied (`grep -F` matches literally). Choose patterns that are:
- From the new code, not the old — pick a fragment that wouldn't exist before the fix
- 15-40 characters, distinctive enough to be unique in the file
- Free of shell special characters (`!`, `$`, `` ` ``, `\`) — these get mangled inside double quotes
- **Good:** `"Auto-append marker if caller"`, `"comments(first: 100)"`, `"addPullRequestReviewThreadReply"`
- **Bad:** `'REPLY_MESSAGE" != *"$MARKER"'` (the `!` and `$` corrupt the pattern)

The `<reply_message>` should follow the format in `assets/reply.tpl`: `"Fixed — <description>"`. The idempotency marker (`<!-- Applied by pr-comment-resolver -->`) is auto-appended by the script if missing — callers do not need to include it.

**When to use `--skip-verify`:** Use for threads where verification against the local file is impossible or unnecessary:
- `outdated: true` AND `originalCode` doesn't match the current file (code changed since review)
- The comment was already addressed in a prior commit (check `git log --oneline -5 -- <path>`)
- The file was deleted or renamed (confirmed in Phase 2)

Pass `-` as a placeholder for `<file_path>` and `<search_pattern>` (ignored with `--skip-verify`, but required for positional parsing):
```bash
./scripts/verify-and-resolve.sh <owner> <repo> <thread_id> - - "<reply_message>" --skip-verify
```

**Parallel execution:** Use multiple parallel Bash tool calls to run verify-and-resolve concurrently. If one call fails, retry it individually after the batch completes.

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

Run `./scripts/<script>.sh --help` for full exit code documentation. Quick reference:

| Exit Code | fetch-unresolved.sh | verify-and-resolve.sh |
|-----------|--------------------|-----------------------|
| 0 | Success → continue | Resolved → report success |
| 1 | Auth error → `gh auth login` | Verification failed → "Fix not found, NOT resolved" |
| 2 | API error → verify PR URL, retry | API error → "Manual action needed" |
| 3 | Rate limited → wait 15 min | Already resolved → skip silently |

## Edge Cases

| Edge Case | Detection | Handling |
|-----------|-----------|----------|
| Comment on deleted file | `path` not in local repo | Skip: "File deleted — cannot apply" |
| File renamed in PR | `path` not found, but `git log --follow --diff-filter=R -- <path>` shows rename | Map to new path, then process normally |
| Outdated suggestion | `originalCode` not in file near line | Skip: "Code changed since suggestion" |
| Binary file | File extension check | Skip: "Binary file — manual review needed" |
| Merge conflict markers | `<<<<<<<` in target file | Stop: "Resolve merge conflicts first" |
| Not on PR branch | Phase 0 branch check | Auto-switch via `gh pr checkout`; if fails, stop and ask user |
| Local branch behind remote | Phase 0 freshness check | `git pull --ff-only`; if diverged, ask user |
| Empty PR | JSON output is `[]` | Exit: "No unresolved comments found" |
| Deleted lines | Line number > file length | Skip: "Target line no longer exists" |
| LEFT-side comment | `side == "LEFT"` | Flag: "Targets base version, manual review needed" |
| PR-level comment | `path` is null | Report as "General Comment" in summary |

## Known Pitfalls

| Pitfall | Cause | Fix |
|---------|-------|-----|
| `FORBIDDEN` on reply posting | Using wrong GraphQL mutation | Script uses `addPullRequestReviewThreadReply` (not `addPullRequestReviewComment` which requires a pending review) |
| Verification fails on valid fix | Shell special chars in search pattern (`!`, `$`, `` ` ``) | Choose plain alphanumeric substrings from the new code |
| Parallel resolve batch partially fails | One bad pattern cancels remaining calls | Retry failed calls individually after the batch completes |
| Duplicate replies on retry | Caller omitted idempotency marker | Script auto-appends marker; no action needed |

## Related Skills

- `darc-review` — Reviews API spec PRs (complementary workflow)
