#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# verify-and-resolve.sh - Verify fix exists, reply, resolve thread
# Usage: ./verify-and-resolve.sh <owner> <repo> <thread_id> <file_path> <search_pattern> <reply_message> [--dry-run] [--skip-verify] [--verbose]
# Exit codes: 0=resolved, 1=verification failed, 2=API error, 3=already resolved
#
# NOTE: This script verifies fixes using simple grep pattern matching.
# The originalCode comparison for outdated suggestion detection happens
# in SKILL.md Phase 2 before this script is called.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

VERBOSE=false

log_error() { echo -e "${RED}ERROR:${NC} $*" >&2; }
log_success() { echo -e "${GREEN}OK:${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}WARN:${NC} $*" >&2; }
log_info() { echo "$*" >&2; }
log_debug() { [[ "$VERBOSE" == "true" ]] && echo -e "DEBUG: $*" >&2 || true; }

# Temp file tracking + cleanup on exit/interrupt
_TEMP_FILES=()
# shellcheck disable=SC2329  # invoked by trap
cleanup() {
    if [[ ${#_TEMP_FILES[@]} -gt 0 ]]; then
        for f in "${_TEMP_FILES[@]}"; do
            rm -f "$f"
        done
    fi
}
trap cleanup EXIT INT TERM

readonly MAX_RETRIES=3
readonly RETRY_DELAYS=(0 2 5)

# Retry wrapper for gh API calls
# Retries on exit code 1 (network/server error) only; fails immediately on other codes
# Returns: result on stdout, exit code 0 on success
retry_gh_api() {
    local attempt=0
    local result
    local exit_code
    local stderr_tmp

    while [[ $attempt -lt $MAX_RETRIES ]]; do
        if [[ ${RETRY_DELAYS[$attempt]} -gt 0 ]]; then
            log_debug "Retry attempt $((attempt + 1))/$MAX_RETRIES, backoff ${RETRY_DELAYS[$attempt]}s"
            log_info "Retrying in ${RETRY_DELAYS[$attempt]}s..."
            sleep "${RETRY_DELAYS[$attempt]}"
        fi

        stderr_tmp=$(mktemp); _TEMP_FILES+=("$stderr_tmp")
        set +e
        result=$("$@" 2>"$stderr_tmp")
        exit_code=$?
        set -e

        if [[ $exit_code -eq 0 ]]; then
            log_debug "API call succeeded (attempt $((attempt + 1)))"
            echo "$result"
            return 0
        fi

        if [[ $exit_code -eq 1 ]]; then
            log_warn "Server/network error (attempt $((attempt + 1))/$MAX_RETRIES): $(cat "$stderr_tmp")"
            attempt=$((attempt + 1))
            continue
        fi

        # Non-retryable error
        log_error "API error (exit $exit_code): $(cat "$stderr_tmp")"
        return $exit_code
    done

    log_error "Server/network error after $MAX_RETRIES retries"
    return 2
}

usage() {
    cat >&2 << EOF
Usage: $(basename "$0") <owner> <repo> <thread_id> <file_path> <search_pattern> <reply_message> [--dry-run] [--skip-verify]

Verify a fix exists in the file, then reply and resolve the thread.

Arguments:
    owner           Repository owner
    repo            Repository name
    thread_id       Review thread ID (PRT_xxx)
    file_path       Local path to the file
    search_pattern  Literal string to verify fix exists (grep -F)
    reply_message   Message to post as reply
    --dry-run       Show what would happen without making changes
    --skip-verify   Skip file verification (for outdated/already-fixed threads).
                    Use '-' as placeholder for <file_path> and <search_pattern>.
    --verbose       Enable debug logging (API calls, retry attempts, checks)

Exit codes:
    0   Success - thread resolved
    1   Verification failed - pattern not found in file
    2   API error - could not reply or resolve
    3   Already resolved - no action needed

Example:
    $(basename "$0") octocat hello-world PRT_xxx src/file.js "null check" "Fixed null check" --dry-run
    $(basename "$0") octocat hello-world PRT_xxx - - "Already fixed" --skip-verify
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
    elif [[ "$arg" == "--verbose" ]]; then
        VERBOSE=true
    else
        ARGS+=("$arg")
    fi
done

if [[ ${#ARGS[@]} -ne 6 ]]; then
    usage
fi

OWNER="${ARGS[0]}"
REPO="${ARGS[1]}"
THREAD_ID="${ARGS[2]}"
FILE_PATH="${ARGS[3]}"
SEARCH_PATTERN="${ARGS[4]}"
REPLY_MESSAGE="${ARGS[5]}"

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

# Step 1: Check if thread is already resolved (before any local verification)
log_debug "Args: owner=$OWNER repo=$REPO thread=$THREAD_ID file=$FILE_PATH"
log_debug "Flags: dry_run=$DRY_RUN skip_verify=$SKIP_VERIFY verbose=$VERBOSE"
log_info "Checking thread status..."
# shellcheck disable=SC2016  # GraphQL variables use $, not shell expansion
check_query='
query($id: ID!) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      isResolved
    }
  }
}'

log_debug "API call: check thread isResolved for $THREAD_ID"
status_response=$(retry_gh_api gh api graphql -f query="$check_query" -f id="$THREAD_ID") || {
    log_error "Failed to check thread status"
    exit 2
}

# Check for GraphQL errors or null node (e.g., invalid thread ID)
if echo "$status_response" | jq -e '.errors' > /dev/null 2>&1; then
    gql_msg=$(echo "$status_response" | jq -r '.errors[0].message // "Unknown GraphQL error"')
    log_error "GraphQL error checking thread status: $gql_msg"
    exit 2
fi
if echo "$status_response" | jq -e '.data.node == null' > /dev/null 2>&1; then
    log_error "Thread not found: $THREAD_ID"
    exit 2
fi

is_resolved=$(echo "$status_response" | jq -r '.data.node.isResolved // false')
if [[ "$is_resolved" == "true" ]]; then
    log_warn "Thread already resolved"
    exit 3
fi

# Step 2: Verify fix exists in file (unless --skip-verify)
if [[ "$SKIP_VERIFY" == "true" ]]; then
    log_info "Skipping file verification (--skip-verify)"
else
    if [[ ! -f "$FILE_PATH" ]]; then
        log_error "File not found: $FILE_PATH"
        exit 1
    fi

    if [[ -z "${SEARCH_PATTERN// /}" ]]; then
        log_error "Search pattern is empty or whitespace-only"
        exit 1
    fi

    log_info "Verifying fix in $FILE_PATH..."
    log_debug "grep -F pattern: '$SEARCH_PATTERN'"
    if grep -qF "$SEARCH_PATTERN" "$FILE_PATH"; then
        log_success "VERIFIED: Pattern found in file"
    else
        log_error "VERIFICATION FAILED: Pattern '$SEARCH_PATTERN' not found in $FILE_PATH"
        exit 1
    fi
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

# Auto-append marker if caller didn't include it, ensuring idempotency
if [[ "$REPLY_MESSAGE" != *"$MARKER"* ]]; then
    REPLY_MESSAGE="${REPLY_MESSAGE}

${MARKER}"
fi

# shellcheck disable=SC2016  # GraphQL variables use $, not shell expansion
thread_query='
query($threadId: ID!) {
  node(id: $threadId) {
    ... on PullRequestReviewThread {
      comments(first: 100) {
        nodes {
          id
          body
        }
      }
    }
  }
}'

thread_response=$(retry_gh_api gh api graphql -f query="$thread_query" -f threadId="$THREAD_ID") || {
    log_warn "Could not fetch existing thread comments, proceeding with post"
    thread_response=""
}

log_debug "API call: fetch thread comments for idempotency check"
if [[ -n "$thread_response" ]] && echo "$thread_response" | jq -e --arg marker "$MARKER" '.data.node.comments.nodes[] | select(.body | contains($marker))' > /dev/null 2>&1; then
    log_debug "Idempotency: found existing reply with marker"
    log_warn "Reply already posted (found marker), skipping to resolve"
else
    # Step 4: Post reply via GraphQL using addPullRequestReviewThreadReply
    # This mutation replies directly to a review thread by its node ID
    log_debug "Idempotency: no existing reply found, will post"
    log_info "Posting reply to thread $THREAD_ID..."
    # shellcheck disable=SC2016  # GraphQL variables use $, not shell expansion
    reply_mutation='
mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
    comment {
      id
    }
  }
}'

    log_debug "API call: addPullRequestReviewThreadReply"
    reply_response=$(retry_gh_api gh api graphql -f query="$reply_mutation" -f threadId="$THREAD_ID" -f body="$REPLY_MESSAGE") || {
        log_error "Failed to post reply"
        exit 2
    }

    # Check for GraphQL-level errors (gh can exit 0 with errors array)
    if echo "$reply_response" | jq -e '.errors and (.errors | length > 0)' > /dev/null 2>&1; then
        gql_msg=$(echo "$reply_response" | jq -r '.errors[0].message // "Unknown GraphQL error"')
        log_error "Reply mutation failed: $gql_msg"
        exit 2
    fi
    log_success "Reply posted"
fi

# Step 5: Resolve the thread
log_info "Resolving thread $THREAD_ID..."
# shellcheck disable=SC2016  # GraphQL variables use $, not shell expansion
resolve_mutation='
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread {
      isResolved
    }
  }
}'

log_debug "API call: resolveReviewThread"
resolve_response=$(retry_gh_api gh api graphql -f query="$resolve_mutation" -f threadId="$THREAD_ID") || {
    log_error "Failed to resolve thread"
    exit 2
}

# Check for GraphQL-level errors before inspecting data payload
if echo "$resolve_response" | jq -e '.errors and (.errors | length > 0)' > /dev/null 2>&1; then
    gql_msg=$(echo "$resolve_response" | jq -r '.errors[0].message // "Unknown GraphQL error"')
    log_error "Thread resolution failed: $gql_msg"
    exit 2
fi

final_status=$(echo "$resolve_response" | jq -r '.data.resolveReviewThread.thread.isResolved // false')
if [[ "$final_status" == "true" ]]; then
    log_success "Thread resolved successfully"
    exit 0
else
    log_error "Thread resolution failed"
    exit 2
fi
