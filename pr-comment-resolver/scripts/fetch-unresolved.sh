#!/usr/bin/env bash
set -euo pipefail

# fetch-unresolved.sh - Fetch all unresolved PR comments with pagination
# Usage: ./fetch-unresolved.sh <owner> <repo> <pr_number>
# Exit codes: 0=success, 1=auth error, 2=not found/API error, 3=rate limited

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
    2   PR not found or API error - check URL; if correct, retry
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
#
# Error detection uses the gh CLI exit code + GraphQL errors field, NOT body
# text grep. Grepping the body caused false positives when PR comments
# mentioned HTTP status codes like "500" or "server error".
#
# Returns: result on stdout, exit code 0 on success
# On failure: prints nothing to stdout, returns non-zero
# Callers MUST check the return code.
retry_api() {
    local attempt=0
    local result
    local exit_code
    local last_failure_type="unknown"  # Track for accurate exit code on exhaustion

    while [[ $attempt -lt $MAX_RETRIES ]]; do
        if [[ ${RETRY_DELAYS[$attempt]} -gt 0 ]]; then
            log_info "Retrying in ${RETRY_DELAYS[$attempt]}s..."
            sleep "${RETRY_DELAYS[$attempt]}"
        fi

        set +e
        result=$("$@" 2>&1)
        exit_code=$?
        set -e

        if [[ $exit_code -eq 0 ]]; then
            # gh succeeded — validate response is JSON before proceeding
            if ! echo "$result" | jq -e . > /dev/null 2>&1; then
                log_warn "Non-JSON response from gh (attempt $((attempt + 1))/$MAX_RETRIES)"
                last_failure_type="server_error"
                attempt=$((attempt + 1))
                continue
            fi

            # Check for GraphQL-level errors
            local gql_error
            gql_error=$(echo "$result" | jq -r '.errors[0].type // empty' 2>/dev/null)

            if [[ -z "$gql_error" ]]; then
                # True success
                echo "$result"
                return 0
            fi

            # GraphQL error — classify by type
            case "$gql_error" in
                RATE_LIMITED)
                    log_warn "GraphQL rate limited (attempt $((attempt + 1))/$MAX_RETRIES)"
                    last_failure_type="rate_limit"
                    attempt=$((attempt + 1))
                    continue
                    ;;
                NOT_FOUND)
                    local msg
                    msg=$(echo "$result" | jq -r '.errors[0].message // "Not found"')
                    log_error "Not found: $msg"
                    return 2
                    ;;
                *)
                    local msg
                    msg=$(echo "$result" | jq -r '.errors[0].message // "Unknown GraphQL error"')
                    log_error "GraphQL error ($gql_error): $msg"
                    return 2
                    ;;
            esac
        fi

        # gh CLI returned non-zero — check stderr for retryable conditions
        # Use the exit code (not body grep) to distinguish error classes
        # gh exits 4 for HTTP 4xx, exits 1 for network/server errors
        if [[ $exit_code -eq 1 ]]; then
            # Network or server error — retryable
            log_warn "Server/network error (attempt $((attempt + 1))/$MAX_RETRIES)"
            last_failure_type="server_error"
            attempt=$((attempt + 1))
            continue
        elif [[ $exit_code -eq 4 ]]; then
            # gh exit code 4 = HTTP 4xx client error
            # Check for rate limit (403 with rate limit message) vs auth (401) vs not found (404)
            if echo "$result" | grep -qi "rate limit"; then
                log_warn "Rate limited (attempt $((attempt + 1))/$MAX_RETRIES)"
                last_failure_type="rate_limit"
                attempt=$((attempt + 1))
                continue
            elif echo "$result" | grep -qi "401\|unauthorized\|Bad credentials"; then
                log_error "Authentication failed"
                return 1
            elif echo "$result" | grep -qi "404\|not found\|Could not resolve"; then
                log_error "PR not found: $OWNER/$REPO#$PR_NUMBER"
                return 2
            else
                log_error "Client error: $result"
                return 2
            fi
        else
            # Unknown exit code — not retryable
            log_error "Unexpected error (exit $exit_code): $result"
            return 2
        fi
    done

    if [[ "$last_failure_type" == "rate_limit" ]]; then
        log_error "Rate limited after $MAX_RETRIES retries"
        return 3
    else
        log_error "Server/network error after $MAX_RETRIES retries"
        return 2
    fi
}

# Fetch review threads with pagination
# Includes diffHunk for extracting original code context
fetch_review_threads() {
    local cursor=""
    local has_next=true
    local all_threads="[]"

    while [[ "$has_next" == "true" ]]; do
        # Use GraphQL variables to prevent injection (owner/repo could contain special chars)
        local query='
        query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $pr) {
              reviewThreads(first: 100, after: $cursor) {
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
                  comments(first: 100) {
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
        }'

        local response
        local api_rc=0
        # Pass variables separately via -f (strings) and -F (non-strings)
        # Capture exit code explicitly — set -e doesn't reliably propagate
        # from functions called inside command substitution in all bash versions.
        if [[ -n "$cursor" ]]; then
            response=$(retry_api gh api graphql -f query="$query" -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" -f cursor="$cursor") || api_rc=$?
        else
            response=$(retry_api gh api graphql -f query="$query" -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER") || api_rc=$?
        fi

        if [[ $api_rc -ne 0 ]]; then
            log_error "API call failed (exit $api_rc)"
            exit $api_rc
        fi

        # Double-check for GraphQL errors (retry_api handles these too,
        # but belt-and-suspenders for edge cases)
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

        log_info "Fetched $(echo "$threads" | jq 'length') threads (hasNext: ${has_next})"
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
        # Extract original code from diffHunk based on diff side
        # RIGHT side (PR head): context lines (" ") + added lines ("+") = current file content
        # LEFT side (base): context lines (" ") + removed lines ("-") = base file content
        (if .diffSide == "LEFT" then
            (.comments.nodes[0].diffHunk // "" |
                split("\n") |
                map(select(startswith(" ") or startswith("-"))) |
                map(.[1:]) |
                join("\n"))
        else
            (.comments.nodes[0].diffHunk // "" |
                split("\n") |
                map(select(startswith(" ") or startswith("+"))) |
                map(.[1:]) |
                join("\n"))
        end) as $originalCode |
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
