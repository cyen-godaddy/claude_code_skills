#!/bin/bash
# ESS Error Search Helper
# Usage: ./ess-query.sh [cluster] [service|index] [hours] [pattern]
#   cluster: Name that maps to ~/essp_creds_<cluster> (default: atlas)
#            e.g., "atlas" reads ~/essp_creds_atlas, "valuation" reads ~/essp_creds_valuation
#   service: container name, index pattern, or '*' for all (default: ans-registry-poc)
#   hours: lookback period (default: 24)
#   pattern: error pattern to search (default: ERROR)
#
# Credential files are flat JSON (no nesting):
#   { "ingestion_url": "...", "ingestion_user": "...", "ingestion_user_password": "...", ... }
#
# Override with CREDS_FILE env var to use a specific file.
#
# Examples:
#   ./ess-query.sh atlas ans-auth 1 timeout
#   ./ess-query.sh valuation valuation-api 24 ERROR
#   ./ess-query.sh valuation nginx 24 502
#   CREDS_FILE=~/my-creds.json ./ess-query.sh atlas ans-auth 1 ERROR

set -euo pipefail

CLUSTER="${1:-atlas}"
SERVICE="${2:-ans-registry-poc}"
HOURS="${3:-24}"
PATTERN="${4:-ERROR}"

# Resolve credentials file: CREDS_FILE env var > ~/essp_creds_<cluster>
if [[ -z "${CREDS_FILE:-}" ]]; then
    CREDS_FILE="$HOME/essp_creds_${CLUSTER}"
fi

if [[ ! -f "$CREDS_FILE" ]]; then
    echo "Error: Credentials file not found at $CREDS_FILE" >&2
    echo "Expected ~/essp_creds_${CLUSTER} or set CREDS_FILE env var" >&2
    exit 1
fi

# Read credentials (flat JSON, no cluster key nesting)
ESS_URL=$(jq -r ".ingestion_url" "$CREDS_FILE")
ESS_USER=$(jq -r ".ingestion_user" "$CREDS_FILE")
ESS_PASS=$(jq -r ".ingestion_user_password" "$CREDS_FILE")

if [[ "$ESS_URL" == "null" || "$ESS_PASS" == "null" ]]; then
    echo "Error: Missing ingestion_url or ingestion_user_password in $CREDS_FILE" >&2
    exit 1
fi

ESS_AUTH="$ESS_USER:$ESS_PASS"

# Build index pattern based on cluster and service
case "$CLUSTER" in
    valuation)
        case "$SERVICE" in
            nginx|nginx-prod)
                INDEX="nginx-prod-prod*"
                ;;
            firehose|app|app-logs)
                INDEX=".ds-logs-gdelastic.firehose-prod*"
                ;;
            *)
                INDEX=".ds-logs-gdelastic.firehose-prod*"
                ;;
        esac
        ;;
    atlas)
        case "$SERVICE" in
            both|"*")
                INDEX=".ds-logs-gdelastic.katana.ans-registry-poc-*,.ds-logs-gdelastic.katana.ans-auth-*"
                ;;
            *)
                INDEX=".ds-logs-gdelastic.katana.${SERVICE}-*"
                ;;
        esac
        ;;
    *)
        # Generic: use service as raw index pattern
        INDEX="*${SERVICE}*"
        ;;
esac

echo "=== ESS Error Search ===" >&2
echo "Cluster: $CLUSTER | Service: $SERVICE | Hours: $HOURS | Pattern: $PATTERN" >&2
echo "Index: $INDEX" >&2
echo "" >&2

# For nginx, search response_code field; for everything else, search message
if [[ "$SERVICE" == "nginx" || "$SERVICE" == "nginx-prod" ]]; then
    curl -s -u "$ESS_AUTH" "$ESS_URL/$INDEX/_search" \
      -H 'Content-Type: application/json' -d "{
      \"size\": 50,
      \"sort\": [{\"@timestamp\": \"desc\"}],
      \"query\": {
        \"bool\": {
          \"must\": [{\"match\": {\"response_code.keyword\": \"$PATTERN\"}}],
          \"filter\": [{\"range\": {\"@timestamp\": {\"gte\": \"now-${HOURS}h\"}}}]
        }
      },
      \"_source\": [\"@timestamp\", \"response_code\", \"url\", \"http_method\", \"request_time\", \"remote_host\"]
    }" | jq -r '.hits.hits[]._source | "\(.["@timestamp"]) [\(.response_code)] \(.http_method) \(.url) (\(.request_time)s)"'
else
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
    }" | jq -r '.hits.hits[]._source | "\(.["@timestamp"]) [\(.kubernetes.container_name // .container_name // "unknown")] \(.message | .[0:200])"'
fi
