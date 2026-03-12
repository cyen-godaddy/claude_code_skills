# PR Comment Resolver Improvements Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make pr-comment-resolver production-grade with robust API handling, edge case coverage, and suggestion block support.

**Architecture:** Extract API operations to testable bash scripts (`fetch-unresolved.sh`, `verify-and-resolve.sh`), keep decision logic in SKILL.md, use templates in `assets/` for consistent output.

**Tech Stack:** Bash, `gh` CLI, `jq`, GraphQL

**Spec:** `docs/superpowers/specs/2026-03-12-pr-comment-resolver-improvements-design.md`

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `pr-comment-resolver/scripts/fetch-unresolved.sh` | Fetch unresolved comments with pagination, retries |
| Create | `pr-comment-resolver/scripts/verify-and-resolve.sh` | Verify fix exists, reply, resolve thread |
| Create | `pr-comment-resolver/assets/commit-message.tpl` | Commit message template |
| Create | `pr-comment-resolver/assets/reply.tpl` | Comment reply template |
| Modify | `pr-comment-resolver/SKILL.md` | Orchestration using scripts + decision logic |

---

## Chunk 1: Templates

### Task 1: Create Commit Message Template

**Files:**
- Create: `pr-comment-resolver/assets/commit-message.tpl`

- [ ] **Step 1: Create assets directory and commit-message.tpl**

```bash
mkdir -p pr-comment-resolver/assets
cat > pr-comment-resolver/assets/commit-message.tpl << 'EOF'
fix: address PR review comments

Applied {applied_count} changes from PR #{pr_number}:
{changes_list}

Skipped {skipped_count} comments (see PR for details)
EOF
```

- [ ] **Step 2: Verify template content**

```bash
cat pr-comment-resolver/assets/commit-message.tpl
```

Expected: Template with `{applied_count}`, `{pr_number}`, `{changes_list}`, `{skipped_count}` placeholders

- [ ] **Step 3: Commit**

```bash
git add pr-comment-resolver/assets/commit-message.tpl
git commit -m "feat: add commit message template for pr-comment-resolver"
```

---

### Task 2: Create Reply Template

**Files:**
- Create: `pr-comment-resolver/assets/reply.tpl`

- [ ] **Step 1: Create reply.tpl**

```bash
cat > pr-comment-resolver/assets/reply.tpl << 'EOF'
Fixed — {description}

<!-- Applied by pr-comment-resolver -->
EOF
```

- [ ] **Step 2: Verify template content**

```bash
cat pr-comment-resolver/assets/reply.tpl
```

Expected: Template with `{description}` placeholder and attribution comment

- [ ] **Step 3: Commit**

```bash
git add pr-comment-resolver/assets/reply.tpl
git commit -m "feat: add reply template for pr-comment-resolver"
```

---

## Chunk 2: fetch-unresolved.sh Script

### Task 3: Create fetch-unresolved.sh

**Files:**
- Create: `pr-comment-resolver/scripts/fetch-unresolved.sh`

**Note:** This script outputs JSON with all fields from the spec including `suggestionStartLine`, `suggestionEndLine`, and `originalCode` for outdated suggestion detection.

- [ ] **Step 1: Create complete fetch-unresolved.sh script**

```bash
mkdir -p pr-comment-resolver/scripts
cat > pr-comment-resolver/scripts/fetch-unresolved.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# fetch-unresolved.sh - Fetch all unresolved PR comments with pagination
# Usage: ./fetch-unresolved.sh <owner> <repo> <pr_number>
# Exit codes: 0=success, 1=auth error, 2=not found, 3=rate limited

readonly MAX_RETRIES=3
readonly RETRY_DELAYS=(0 2 5)

# Colors for stderr messages
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_error() { echo -e "${RED}ERROR:${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}WARN:${NC} $*" >&2; }
log_info() { echo "$*" >&2; }

usage() {
    cat >&2 << EOF
Usage: $(basename "$0") <owner> <repo> <pr_number>

Fetch all unresolved PR review comments with pagination and retry logic.

Arguments:
    owner       Repository owner (e.g., 'octocat')
    repo        Repository name (e.g., 'hello-world')
    pr_number   Pull request number (e.g., '123')

Exit codes:
    0   Success - JSON output on stdout
    1   Authentication error - run 'gh auth login'
    2   PR not found - check URL format
    3   Rate limited - try again later

Example:
    $(basename "$0") octocat hello-world 123
EOF
    exit 1
}

# Validate arguments
if [[ $# -ne 3 ]]; then
    usage
fi

OWNER="$1"
REPO="$2"
PR_NUMBER="$3"

# Validate PR number is numeric
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    log_error "PR number must be numeric, got: $PR_NUMBER"
    exit 2
fi

# Check gh CLI is available
if ! command -v gh &> /dev/null; then
    log_error "gh CLI not found. Install from https://cli.github.com"
    exit 1
fi

# Check gh is authenticated
if ! gh auth status &> /dev/null; then
    log_error "gh CLI not authenticated. Run 'gh auth login'"
    exit 1
fi

# Check jq is available
if ! command -v jq &> /dev/null; then
    log_error "jq not found. Install jq for JSON processing"
    exit 1
fi

# Retry wrapper for API calls
# Retries on 5xx errors and rate limits (429), fails immediately on other 4xx
retry_api() {
    local attempt=0
    local result
    local exit_code

    while [[ $attempt -lt $MAX_RETRIES ]]; do
        if [[ ${RETRY_DELAYS[$attempt]} -gt 0 ]]; then
            log_info "Retrying in ${RETRY_DELAYS[$attempt]}s..."
            sleep "${RETRY_DELAYS[$attempt]}"
        fi

        set +e
        result=$("$@" 2>&1)
        exit_code=$?
        set -e

        # Check for rate limiting (429)
        if echo "$result" | grep -qi "rate limit\|API rate limit exceeded\|429"; then
            log_warn "Rate limited (attempt $((attempt + 1))/$MAX_RETRIES)"
            ((attempt++))
            continue
        fi

        # Check for server errors (5xx)
        if echo "$result" | grep -qi "502\|503\|504\|500\|server error"; then
            log_warn "Server error (attempt $((attempt + 1))/$MAX_RETRIES)"
            ((attempt++))
            continue
        fi

        # Check for auth errors (401) - fail immediately
        if echo "$result" | grep -qi "401\|unauthorized\|authentication"; then
            log_error "Authentication failed"
            exit 1
        fi

        # Check for not found (404) - fail immediately
        if echo "$result" | grep -qi "404\|not found\|Could not resolve"; then
            log_error "PR not found: $OWNER/$REPO#$PR_NUMBER"
            exit 2
        fi

        # Success or non-retryable error
        echo "$result"
        return $exit_code
    done

    log_error "Rate limited after $MAX_RETRIES attempts"
    exit 3
}

# Fetch review threads with pagination
# Includes diffHunk for extracting original code context
fetch_review_threads() {
    local cursor=""
    local has_next=true
    local all_threads="[]"

    while [[ "$has_next" == "true" ]]; do
        local cursor_arg=""
        if [[ -n "$cursor" ]]; then
            cursor_arg=", after: \"$cursor\""
        fi

        local query="
        {
          repository(owner: \"$OWNER\", name: \"$REPO\") {
            pullRequest(number: $PR_NUMBER) {
              reviewThreads(first: 100$cursor_arg) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                nodes {
                  id
                  isResolved
                  isOutdated
                  path
                  line
                  startLine
                  originalLine
                  originalStartLine
                  diffSide
                  comments(first: 10) {
                    nodes {
                      databaseId
                      body
                      diffHunk
                      author {
                        login
                      }
                    }
                  }
                }
              }
            }
          }
        }"

        local response
        response=$(retry_api gh api graphql -f query="$query")

        # Check for errors in response
        if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
            local error_msg
            error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
            log_error "GraphQL error: $error_msg"
            exit 2
        fi

        # Extract threads and pagination info
        local threads
        threads=$(echo "$response" | jq '.data.repository.pullRequest.reviewThreads.nodes // []')
        has_next=$(echo "$response" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false')
        cursor=$(echo "$response" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""')

        # Merge threads
        all_threads=$(echo "$all_threads" "$threads" | jq -s 'add')

        log_info "Fetched $(echo "$threads" | jq 'length') threads (hasNext: $has_next)"
    done

    echo "$all_threads"
}

# Transform raw threads to output format with all spec fields
# Includes suggestionStartLine, suggestionEndLine, originalCode for outdated detection
transform_threads() {
    local threads="$1"

    echo "$threads" | jq '
        [.[] | select(.isResolved == false) |
        # Extract suggestion code and line info from body
        (.comments.nodes[0].body |
            if test("```suggestion") then
                {
                    hasSuggestion: true,
                    suggestionCode: (capture("```suggestion\n(?<code>[\\s\\S]*?)\n```") | .code // null)
                }
            else
                {hasSuggestion: false, suggestionCode: null}
            end
        ) as $suggestion |
        # Extract original code from diffHunk (lines starting with - or space after @@)
        (.comments.nodes[0].diffHunk // "" |
            split("\n") |
            map(select(startswith(" ") or startswith("-"))) |
            map(.[1:]) |
            join("\n")
        ) as $originalCode |
        {
            threadId: .id,
            commentId: .comments.nodes[0].databaseId,
            path: .path,
            line: (.line // .startLine),
            startLine: .startLine,
            suggestionStartLine: (.originalStartLine // .startLine),
            suggestionEndLine: (.originalLine // .line // .startLine),
            side: .diffSide,
            body: .comments.nodes[0].body,
            author: .comments.nodes[0].author.login,
            outdated: .isOutdated,
            originalCode: $originalCode,
            hasSuggestion: $suggestion.hasSuggestion,
            suggestionCode: $suggestion.suggestionCode,
            replies: [.comments.nodes[1:][].body // empty]
        }]
    '
}

# Main execution
log_info "Fetching unresolved comments for $OWNER/$REPO#$PR_NUMBER..."

raw_threads=$(fetch_review_threads)
thread_count=$(echo "$raw_threads" | jq 'length')
log_info "Found $thread_count total review threads"

transformed=$(transform_threads "$raw_threads")
unresolved_count=$(echo "$transformed" | jq 'length')
log_info "Found $unresolved_count unresolved threads"

# Output final JSON
echo "$transformed" | jq '.'
SCRIPT
chmod +x pr-comment-resolver/scripts/fetch-unresolved.sh
```

- [ ] **Step 2: Test argument validation - missing args**

```bash
./pr-comment-resolver/scripts/fetch-unresolved.sh 2>&1 || true
```

Expected: Usage message printed to stderr, non-zero exit

- [ ] **Step 3: Test argument validation - non-numeric PR**

```bash
./pr-comment-resolver/scripts/fetch-unresolved.sh owner repo abc 2>&1 || true
```

Expected: Error "PR number must be numeric"

- [ ] **Step 4: Commit**

```bash
git add pr-comment-resolver/scripts/fetch-unresolved.sh
git commit -m "feat: add fetch-unresolved.sh with pagination and suggestion parsing

- Fetches all unresolved review threads with pagination
- Retries with exponential backoff for transient failures
- Parses suggestion blocks from comment body
- Extracts originalCode from diffHunk for outdated detection
- Outputs JSON with all spec fields including suggestionStartLine/EndLine"
```

---

## Chunk 3: verify-and-resolve.sh Script

### Task 4: Create verify-and-resolve.sh

**Files:**
- Create: `pr-comment-resolver/scripts/verify-and-resolve.sh`

**Note:** This script performs simple grep-based verification that a fix exists in the file. The more sophisticated `originalCode` comparison for outdated suggestion detection happens in SKILL.md Phase 2 before this script is called.

- [ ] **Step 1: Create complete verify-and-resolve.sh script**

```bash
cat > pr-comment-resolver/scripts/verify-and-resolve.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# verify-and-resolve.sh - Verify fix exists, reply, resolve thread
# Usage: ./verify-and-resolve.sh <owner> <repo> <thread_id> <comment_id> <file_path> <search_pattern> <reply_message> [--dry-run]
# Exit codes: 0=resolved, 1=verification failed, 2=API error, 3=already resolved
#
# NOTE: This script verifies fixes using simple grep pattern matching.
# The originalCode comparison for outdated suggestion detection happens
# in SKILL.md Phase 2 before this script is called.

readonly MAX_RETRIES=3
readonly RETRY_DELAYS=(0 2 5)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_error() { echo -e "${RED}ERROR:${NC} $*" >&2; }
log_success() { echo -e "${GREEN}OK:${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}WARN:${NC} $*" >&2; }
log_info() { echo "$*" >&2; }

usage() {
    cat >&2 << EOF
Usage: $(basename "$0") <owner> <repo> <thread_id> <comment_id> <file_path> <search_pattern> <reply_message> [--dry-run]

Verify a fix exists in the file, then reply and resolve the thread.

Arguments:
    owner           Repository owner
    repo            Repository name
    thread_id       Review thread ID (PRT_xxx)
    comment_id      Comment database ID
    file_path       Local path to the file
    search_pattern  Literal string to verify fix exists (grep -F)
    reply_message   Message to post as reply
    --dry-run       Show what would happen without making changes

Exit codes:
    0   Success - thread resolved
    1   Verification failed - pattern not found in file
    2   API error - could not reply or resolve
    3   Already resolved - no action needed

Example:
    $(basename "$0") octocat hello-world PRT_xxx 12345 src/file.js "null check" "Fixed null check" --dry-run
EOF
    exit 1
}

DRY_RUN=false

# Parse arguments - extract --dry-run flag
ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        DRY_RUN=true
    else
        ARGS+=("$arg")
    fi
done

if [[ ${#ARGS[@]} -ne 7 ]]; then
    usage
fi

OWNER="${ARGS[0]}"
REPO="${ARGS[1]}"
THREAD_ID="${ARGS[2]}"
COMMENT_ID="${ARGS[3]}"
FILE_PATH="${ARGS[4]}"
SEARCH_PATTERN="${ARGS[5]}"
REPLY_MESSAGE="${ARGS[6]}"

# Validate prerequisites
if ! command -v gh &> /dev/null; then
    log_error "gh CLI not found"
    exit 2
fi

if ! gh auth status &> /dev/null; then
    log_error "gh CLI not authenticated"
    exit 2
fi

# Step 1: Check if file exists
if [[ ! -f "$FILE_PATH" ]]; then
    log_error "File not found: $FILE_PATH"
    exit 1
fi

# Step 2: Verify fix exists in file (literal string match)
log_info "Verifying fix in $FILE_PATH..."
if grep -qF "$SEARCH_PATTERN" "$FILE_PATH"; then
    log_success "VERIFIED: Pattern found in file"
else
    log_error "VERIFICATION FAILED: Pattern '$SEARCH_PATTERN' not found in $FILE_PATH"
    exit 1
fi

# Step 3: Check if thread is already resolved
log_info "Checking thread status..."
check_query='
query($id: ID!) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      isResolved
    }
  }
}'

status_response=$(gh api graphql -f query="$check_query" -f id="$THREAD_ID" 2>&1) || {
    log_error "Failed to check thread status: $status_response"
    exit 2
}

is_resolved=$(echo "$status_response" | jq -r '.data.node.isResolved // false')
if [[ "$is_resolved" == "true" ]]; then
    log_warn "Thread already resolved"
    exit 3
fi

# Dry run stops here
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would post reply: $REPLY_MESSAGE"
    log_info "[DRY-RUN] Would resolve thread: $THREAD_ID"
    log_success "Dry run complete - no changes made"
    exit 0
fi

# Step 4: Post reply to the comment
log_info "Posting reply to comment $COMMENT_ID..."
reply_response=$(gh api "repos/$OWNER/$REPO/pulls/comments/$COMMENT_ID/replies" \
    -f body="$REPLY_MESSAGE" 2>&1) || {
    log_error "Failed to post reply: $reply_response"
    exit 2
}
log_success "Reply posted"

# Step 5: Resolve the thread
log_info "Resolving thread $THREAD_ID..."
resolve_mutation='
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread {
      isResolved
    }
  }
}'

resolve_response=$(gh api graphql -f query="$resolve_mutation" -f threadId="$THREAD_ID" 2>&1) || {
    log_error "Failed to resolve thread: $resolve_response"
    exit 2
}

final_status=$(echo "$resolve_response" | jq -r '.data.resolveReviewThread.thread.isResolved // false')
if [[ "$final_status" == "true" ]]; then
    log_success "Thread resolved successfully"
    exit 0
else
    log_error "Thread resolution failed"
    exit 2
fi
SCRIPT
chmod +x pr-comment-resolver/scripts/verify-and-resolve.sh
```

- [ ] **Step 2: Test argument validation**

```bash
./pr-comment-resolver/scripts/verify-and-resolve.sh 2>&1 || true
```

Expected: Usage message with arguments and exit codes

- [ ] **Step 3: Test dry-run flag parsing**

```bash
./pr-comment-resolver/scripts/verify-and-resolve.sh --dry-run 2>&1 || true
```

Expected: Usage message (still missing required args)

- [ ] **Step 4: Commit**

```bash
git add pr-comment-resolver/scripts/verify-and-resolve.sh
git commit -m "feat: add verify-and-resolve.sh with dry-run support

- Verifies fix exists in file before resolving
- Posts reply and resolves thread atomically
- Supports --dry-run for testing
- Clear exit codes for each failure mode"
```

---

## Chunk 4: Update SKILL.md

### Task 5: Rewrite SKILL.md with New Structure

**Files:**
- Modify: `pr-comment-resolver/SKILL.md`

- [ ] **Step 1: Read current SKILL.md**

```bash
cat pr-comment-resolver/SKILL.md
```

- [ ] **Step 2: Replace SKILL.md with updated version**

```bash
cat > pr-comment-resolver/SKILL.md << 'EOF'
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
   ├─ Check: Does file at path:line contain originalCode?
   │   ├─ Yes → Apply suggestionCode directly (replace lines)
   │   └─ No → Flag "outdated suggestion — code has changed"
   └─ If outdated: true → Flag even if code matches (GitHub marked it stale)

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
- Lack context to be confident
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
# Use template from assets/commit-message.tpl
git add -A && git commit -m "fix: address PR review comments

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
./scripts/verify-and-resolve.sh <owner> <repo> <thread_id> <comment_id> <file_path> "<search_pattern>" "<reply_message>"
```

Output verification results:
```
Verifying fixes in files...
✓ file.js:55 — VERIFIED: Pattern found, thread resolved
✓ config.ts:42 — VERIFIED: Pattern found, thread resolved
✗ api.ts:30 — NOT FOUND: Fix not in file, thread NOT resolved
```

**CRITICAL:** Only resolve comments whose fixes are verified present in the pushed code.

## Error Handling

| Exit Code | Script | Meaning | Action |
|-----------|--------|---------|--------|
| 0 | fetch-unresolved.sh | Success | Continue |
| 1 | fetch-unresolved.sh | Auth error | Stop: "Run `gh auth login`" |
| 2 | fetch-unresolved.sh | PR not found | Stop: "Check URL format" |
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
EOF
```

- [ ] **Step 3: Verify SKILL.md updated**

```bash
head -20 pr-comment-resolver/SKILL.md
```

Expected: Version 2.0, updated metadata

- [ ] **Step 4: Commit**

```bash
git add pr-comment-resolver/SKILL.md
git commit -m "feat: rewrite pr-comment-resolver SKILL.md with script integration

- Use scripts for API operations (fetch-unresolved.sh, verify-and-resolve.sh)
- Add explicit user permission gate before commits/resolves
- Add suggestion block handling with decision tree
- Add originalCode comparison for outdated suggestion detection
- Improve error handling table with exit codes
- Add edge case table"
```

---

## Chunk 5: Final Verification

### Task 6: Verify Complete Implementation

- [ ] **Step 1: Verify file structure**

```bash
find pr-comment-resolver -type f | sort
```

Expected:
```
pr-comment-resolver/SKILL.md
pr-comment-resolver/assets/commit-message.tpl
pr-comment-resolver/assets/reply.tpl
pr-comment-resolver/scripts/fetch-unresolved.sh
pr-comment-resolver/scripts/verify-and-resolve.sh
```

- [ ] **Step 2: Verify scripts are executable**

```bash
ls -la pr-comment-resolver/scripts/
```

Expected: Both .sh files have execute permission (-rwxr-xr-x or similar)

- [ ] **Step 3: Verify fetch-unresolved.sh usage**

```bash
./pr-comment-resolver/scripts/fetch-unresolved.sh 2>&1 | head -20
```

Expected: Usage message with arguments and exit codes

- [ ] **Step 4: Verify verify-and-resolve.sh usage**

```bash
./pr-comment-resolver/scripts/verify-and-resolve.sh 2>&1 | head -20
```

Expected: Usage message with arguments and exit codes

- [ ] **Step 5: Verify git status is clean**

```bash
git status
```

Expected: Working tree clean (all changes committed)

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Create commit message template | assets/commit-message.tpl |
| 2 | Create reply template | assets/reply.tpl |
| 3 | Create fetch-unresolved.sh | scripts/fetch-unresolved.sh |
| 4 | Create verify-and-resolve.sh | scripts/verify-and-resolve.sh |
| 5 | Rewrite SKILL.md | SKILL.md |
| 6 | Final verification | All files |
