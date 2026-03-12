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
            attempt=$((attempt + 1))
            continue
        fi

        # Check for server errors (5xx)
        if echo "$result" | grep -qi "502\|503\|504\|500\|server error"; then
            log_warn "Server error (attempt $((attempt + 1))/$MAX_RETRIES)"
            attempt=$((attempt + 1))
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
        }'

        local response
        # Pass variables separately via -f (strings) and -F (non-strings)
        if [[ -n "$cursor" ]]; then
            response=$(retry_api gh api graphql -f query="$query" -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" -f cursor="$cursor")
        else
            response=$(retry_api gh api graphql -f query="$query" -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER")
        fi

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
