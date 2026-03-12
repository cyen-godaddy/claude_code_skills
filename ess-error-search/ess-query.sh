#!/bin/bash
# ESS Error Search Helper
# Usage: ./ess-query.sh [service] [hours] [pattern]
#   service: ans-registry-poc, ans-auth, or both (default: both)
#   hours: lookback period (default: 24)
#   pattern: error pattern to search (default: ERROR)

set -euo pipefail

# Load credentials
CREDS_FILE="${CREDS_FILE:-$(dirname "$0")/../../../git/ans-registry-poc/essp_creds}"
if [[ -f "$CREDS_FILE" ]]; then
    ESS_URL=$(jq -r .ingestion_url "$CREDS_FILE")
    ESS_PASS=$(jq -r .ingestion_user_password "$CREDS_FILE")
    ESS_AUTH="admin:$ESS_PASS"
else
    echo "Error: Credentials file not found at $CREDS_FILE" >&2
    echo "Set CREDS_FILE env var or ensure essp_creds exists" >&2
    exit 1
fi

SERVICE="${1:-both}"
HOURS="${2:-24}"
PATTERN="${3:-ERROR}"

# Build index pattern (only ans-registry-poc and ans-auth)
case "$SERVICE" in
    both|"*")
        INDEX=".ds-logs-gdelastic.katana.ans-registry-poc-*,.ds-logs-gdelastic.katana.ans-auth-*"
        ;;
    ans-registry-poc|ans-auth)
        INDEX=".ds-logs-gdelastic.katana.${SERVICE}-*"
        ;;
    *)
        echo "Error: Invalid service '$SERVICE'. Use: ans-registry-poc, ans-auth, or both" >&2
        exit 1
        ;;
esac

echo "=== ESS Error Search ===" >&2
echo "Service: $SERVICE | Hours: $HOURS | Pattern: $PATTERN" >&2
echo "" >&2

# Execute query
curl -s -u "$ESS_AUTH" "$ESS_URL/$INDEX/_search" \
  -H 'Content-Type: application/json' -d "{
  \"size\": 50,
  \"sort\": [{\"@timestamp\": \"desc\"}],
  \"query\": {
    \"bool\": {
      \"must\": [{\"match\": {\"message\": \"$PATTERN\"}}],
      \"filter\": [{\"range\": {\"@timestamp\": {\"gte\": \"now-${HOURS}h\"}}}]
    }
  }
}" | jq -r '.hits.hits[]._source | "\(.["@timestamp"]) [\(.container_name)] \(.message | .[0:200])"'
