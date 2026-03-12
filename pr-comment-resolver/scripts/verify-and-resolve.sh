#!/usr/bin/env bash
set -euo pipefail

# verify-and-resolve.sh - Verify fix exists, reply, resolve thread
# Usage: ./verify-and-resolve.sh <owner> <repo> <thread_id> <comment_id> <file_path> <search_pattern> <reply_message> [--dry-run]
# Exit codes: 0=resolved, 1=verification failed, 2=API error, 3=already resolved
#
# NOTE: This script verifies fixes using simple grep pattern matching.
# The originalCode comparison for outdated suggestion detection happens
# in SKILL.md Phase 2 before this script is called.

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
Usage: $(basename "$0") <owner> <repo> <thread_id> <comment_id> <file_path> <search_pattern> <reply_message> [--dry-run] [--skip-verify]

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
    --skip-verify   Skip file verification (for outdated/already-fixed threads)

Exit codes:
    0   Success - thread resolved
    1   Verification failed - pattern not found in file
    2   API error - could not reply or resolve
    3   Already resolved - no action needed

Example:
    $(basename "$0") octocat hello-world PRT_xxx 12345 src/file.js "null check" "Fixed null check" --dry-run
    $(basename "$0") octocat hello-world PRT_xxx 12345 - - "Already fixed" --skip-verify
EOF
    exit 1
}

DRY_RUN=false
SKIP_VERIFY=false

# Parse arguments - extract flags
ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        DRY_RUN=true
    elif [[ "$arg" == "--skip-verify" ]]; then
        SKIP_VERIFY=true
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

if ! command -v jq &> /dev/null; then
    log_error "jq not found. Install jq for JSON processing"
    exit 2
fi

# Step 1 & 2: Verify fix exists in file (unless --skip-verify)
if [[ "$SKIP_VERIFY" == "true" ]]; then
    log_info "Skipping file verification (--skip-verify)"
else
    if [[ ! -f "$FILE_PATH" ]]; then
        log_error "File not found: $FILE_PATH"
        exit 1
    fi

    log_info "Verifying fix in $FILE_PATH..."
    if grep -qF "$SEARCH_PATTERN" "$FILE_PATH"; then
        log_success "VERIFIED: Pattern found in file"
    else
        log_error "VERIFICATION FAILED: Pattern '$SEARCH_PATTERN' not found in $FILE_PATH"
        exit 1
    fi
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

# Idempotency check: See if we already posted a reply with our marker
# This prevents duplicate replies on retry when reply posted but resolve failed
log_info "Checking for existing reply..."
MARKER="<!-- Applied by pr-comment-resolver -->"
existing_replies=$(gh api "repos/$OWNER/$REPO/pulls/comments/$COMMENT_ID/replies" --paginate 2>&1) || {
    log_warn "Could not fetch existing replies, proceeding with post"
    existing_replies="[]"
}

if echo "$existing_replies" | jq -e ".[] | select(.body | contains(\"$MARKER\"))" > /dev/null 2>&1; then
    log_warn "Reply already posted (found marker), skipping to resolve"
else
    # Step 4: Post reply to the comment
    log_info "Posting reply to comment $COMMENT_ID..."
    reply_response=$(gh api "repos/$OWNER/$REPO/pulls/comments/$COMMENT_ID/replies" \
        -f body="$REPLY_MESSAGE" 2>&1) || {
        log_error "Failed to post reply: $reply_response"
        exit 2
    }
    log_success "Reply posted"
fi

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
