---
name: pr-comment-resolver
description: Use when addressing GitHub PR review comments, resolving Copilot suggestions, fixing code review feedback, or applying reviewer suggestions in bulk. Triggers on PR URLs, "resolve comments", "address feedback", "fix review comments".
license: Proprietary
metadata:
  author: godaddy-platform
  version: "1.1"
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
ANALYZE BEFORE APPLYING. FLAG WHAT DOESN'T MAKE SENSE. NEVER COMMIT CHANGES WITHOUT ASKING.
```

## Input Formats

Accept PR URLs in any format:
- `https://github.com/owner/repo/pull/123`
- `owner/repo#123`
- Just `123` if already in the repo

## Execution

### Phase 1: Fetch Unresolved Comments

```bash
# Extract owner/repo/number from URL, then:

# Get thread resolution status
gh api graphql -f query='
{
  repository(owner: "OWNER", name: "REPO") {
    pullRequest(number: NUMBER) {
      reviewThreads(first: 50) {
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes {
              databaseId
              body
              path
              line
            }
          }
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)'
```

Group unresolved comments by file path.

### Phase 2: Analyze & Apply

For each unresolved comment:

1. **Read** the target file at the specified line
2. **Understand** what the comment is asking for
3. **Decide:**
   - Suggestion makes sense → Apply the fix using Edit tool
   - Suggestion unclear/wrong → Flag it, skip, continue
4. **Track** applied changes and skipped comments with reasons

**Apply when:**
- Corrects an actual bug or inconsistency
- Aligns with project conventions
- Localized fix that won't break other code

**Flag and skip when:**
- Misunderstands the code's intent
- Would introduce a bug
- Ambiguous or contradictory
- Lack context to be confident

### Phase 3: Report & Offer Next Steps

Output during processing:
```
✓ file.js:55 — Added null check before access
⊘ config.ts:42 — SKIPPED: Conflicts with existing error handling pattern
```

Summary report:
```
## PR Comment Resolution Summary

**Applied:** 4 changes
**Skipped:** 2 comments

### Applied Changes
- `collect.sh:55` — Added empty NS check with error exit
- `collect.sh:73` — Guarded NS2 with conditional

### Skipped (Needs Review)
- `config.js:42` — Suggestion conflicts with existing error handling pattern
- `api.ts:18` — Ambiguous: unclear which validation to add

### Next Steps
Would you like me to commit, push, and resolve the applied comments?
```

### Phase 4: Verify Before Resolving

<HARD-GATE>
NEVER resolve a comment without verifying the fix is in the file. A resolved comment with no actual change is worse than an unresolved one.
</HARD-GATE>

After committing and pushing, verify EVERY applied fix before resolving its comment:

1. For each applied change, grep or read the file to confirm the fix is present
2. Output verification results:
```
Verifying fixes in files...
✓ collect.sh:53 — VERIFIED: "Unable to determine authoritative nameserver" found
✓ collect.sh:79 — VERIFIED: 'if [ -n "${NS2:-}" ]' found
✗ README.md:18 — NOT FOUND: description unchanged
```
3. Only resolve comments whose fixes are verified
4. For any fix that fails verification, report it and DO NOT resolve the comment

If user approves next steps:

```bash
# Commit changes
git add -A && git commit -m "fix: address PR review comments"

# Push
git push

# VERIFY each fix before resolving
# For each applied comment, grep/read the file to confirm the change exists.
# Only then reply and resolve:
gh api repos/OWNER/REPO/pulls/NUMBER/comments/COMMENT_ID/replies \
  -f body="Fixed — DESCRIPTION"

gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "THREAD_ID"}) { thread { isResolved } } }'
```

## Error Handling

| Error | Action |
|-------|--------|
| PR not found | Exit: "PR not found. Check the URL format: owner/repo#number" |
| No unresolved comments | Exit: "No unresolved comments found on this PR" |
| File not in local repo | Skip: "File not found locally — comment may be on deleted file" |
| `gh` CLI missing | Exit: "Install gh CLI: https://cli.github.com" |
| Auth failure | Exit: "Run `gh auth login` to authenticate" |
| Not on PR branch | Warn: "You may not be on the PR branch — changes might not match" |

## Prerequisites

- `gh` CLI installed and authenticated (`gh auth status`)
- Local clone of the repository
- Ideally on the PR branch (`gh pr checkout NUMBER`)

## Related Skills

- `darc-review` — Reviews API spec PRs (complementary workflow)
