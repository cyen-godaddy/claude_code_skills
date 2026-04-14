---
name: ess-error-search
description: Use when searching for application errors, exceptions, or service failures in ESS/Elasticsearch logs. Triggers on phrases like "find errors", "check logs", "debug service", "look for failures in ESS", "search ESSP", "check nginx errors", "valuation logs".
---

# ESS Error Search

## Overview

Query Elastic Cloud (ESSP) clusters to find service errors and exceptions. Multiple clusters exist for different services. Always start by identifying the correct cluster and credentials.

## Clusters

| Cluster | Creds File | Services |
|---------|------------|----------|
| **Valuation** | `~/essp_creds_valuation` | valuation-api, valuation-proxy, rate-limiter, valuation-auth, valuation-batch |
| **Atlas-AI** | `~/essp_creds_atlas` | ans-registry-poc, ans-auth, agent2agent |

## Credentials

Each cluster has its own flat JSON file at `~/essp_creds_<cluster>`:

```json
{
  "essp_id": "<essp-deployment-id>",
  "deployment_id": "<cloud-deployment-id>",
  "ingestion_user": "admin",
  "ingestion_user_password": "<password>",
  "ingestion_url": "https://<es-host>.es.us-west-2.aws.found.io:9243",
  "ingestion_host": "<es-host>.es.us-west-2.aws.found.io",
  "ingestion_port": 9243,
  "kibana_url": "https://<kibana-host>.kb.us-west-2.aws.found.io:9243"
}
```

### Adding a New Cluster

```bash
# Fetch from AWS Secrets Manager and save as ~/essp_creds_<cluster>
aws secretsmanager get-secret-value --secret-id essp_deployment_credentials --query SecretString --output text > ~/essp_creds_<cluster>
```

### Reading Credentials

```bash
CREDS_FILE=~/essp_creds_atlas
ESS_URL=$(jq -r ".ingestion_url" "$CREDS_FILE")
ESS_PASS=$(jq -r ".ingestion_user_password" "$CREDS_FILE")
ESS_AUTH="$(jq -r ".ingestion_user" "$CREDS_FILE"):$ESS_PASS"
```

## Preferred Approach: Use ess-query.sh

**ALWAYS use the `ess-query.sh` helper script first** instead of manual curl commands. It handles credentials, index selection, and output formatting automatically:

```bash
~/.claude/skills/ess-error-search/ess-query.sh <cluster> <service|nginx> <hours> <pattern>
```

The `cluster` argument maps to `~/essp_creds_<cluster>`. Override with `CREDS_FILE` env var.

Examples:
```bash
~/.claude/skills/ess-error-search/ess-query.sh valuation nginx 6 500,502,503,504
~/.claude/skills/ess-error-search/ess-query.sh valuation valuation-api 6 ERROR
~/.claude/skills/ess-error-search/ess-query.sh atlas ans-auth 1 timeout
```

Only fall back to manual curl commands if the script doesn't support your specific query (e.g., custom aggregations, field mapping checks).

## Manual Investigation (Fallback)

If `ess-query.sh` is insufficient, follow this order — do NOT skip steps:

1. **List indices** to find correct index pattern
2. **Sample docs** (size=3) to discover field names
3. **Check field mappings** for keyword vs text types
4. **Aggregate** to get error counts/distribution
5. **Get error samples** with relevant filters

## Index Patterns by Cluster

### Valuation Cluster

| Log Type | Index Pattern | Key Fields |
|----------|---------------|------------|
| Nginx access logs | `nginx-prod-prod*` | `response_code` (string), `url`, `http_method`, `request_time`, `remote_host`, `agent` |
| App logs (firehose) | `.ds-logs-gdelastic.firehose-prod*` | `message` (contains embedded JSON/text), `kubernetes.container_name` (keyword type, no `.keyword` suffix) |

### Atlas-AI Cluster

| Log Type | Index Pattern | Key Fields |
|----------|---------------|------------|
| Katana app logs | `.ds-logs-gdelastic.katana.{app}-{env}-*` | `message`, `container_name`, `KATANA_APP`, `KATANA_ENVIRONMENT` |

## Common Queries

### Step 1: List Available Indices

```bash
curl -s -u "$ESS_AUTH" "$ESS_URL/_cat/indices/INDEX_PATTERN*?h=index,docs.count,store.size&s=index:desc" | head -10
```

### Step 2: Sample Documents to Discover Fields

```bash
curl -s -u "$ESS_AUTH" "$ESS_URL/INDEX_PATTERN*/_search" -H 'Content-Type: application/json' -d '{
  "size": 3, "sort": [{"@timestamp": "desc"}],
  "query": {"range": {"@timestamp": {"gte": "now-24h"}}}
}' | python3 -m json.tool | head -80
```

### Step 3: Aggregate Status Codes (Nginx)

```bash
curl -s -u "$ESS_AUTH" "$ESS_URL/nginx-prod-prod*/_search" -H 'Content-Type: application/json' -d '{
  "size": 0,
  "query": {"range": {"@timestamp": {"gte": "now-24h"}}},
  "aggs": {"status_codes": {"terms": {"field": "response_code.keyword", "size": 20, "order": {"_key": "asc"}}}}
}'
```

### Step 4: Get 5xx Errors (Nginx)

```bash
curl -s -u "$ESS_AUTH" "$ESS_URL/nginx-prod-prod*/_search" -H 'Content-Type: application/json' -d '{
  "size": 20, "sort": [{"@timestamp": "desc"}],
  "query": {"bool": {"must": [
    {"range": {"@timestamp": {"gte": "now-24h"}}},
    {"terms": {"response_code.keyword": ["500","502","503","504"]}}
  ]}},
  "_source": ["@timestamp", "response_code", "url", "http_method", "request_time", "remote_host", "kubernetes.pod_name"]
}'
```

### Step 5: Aggregate by Container (App Logs)

```bash
curl -s -u "$ESS_AUTH" "$ESS_URL/.ds-logs-gdelastic.firehose-prod*/_search" -H 'Content-Type: application/json' -d '{
  "size": 0,
  "query": {"range": {"@timestamp": {"gte": "now-24h"}}},
  "aggs": {"containers": {"terms": {"field": "kubernetes.container_name", "size": 30}}}
}'
```

### Step 6: Find App Errors (Firehose, Excluding Noise)

```bash
curl -s -u "$ESS_AUTH" "$ESS_URL/.ds-logs-gdelastic.firehose-prod*/_search" -H 'Content-Type: application/json' -d '{
  "size": 15, "sort": [{"@timestamp": "desc"}],
  "query": {"bool": {
    "must": [
      {"range": {"@timestamp": {"gte": "now-24h"}}},
      {"terms": {"kubernetes.container_name": ["valuation-api", "valuation-api-batch", "valuation-batch", "valuation-auth", "rate-limiter"]}},
      {"bool": {"should": [
        {"match_phrase": {"message": "Traceback"}},
        {"match_phrase": {"message": "Exception"}},
        {"match_phrase": {"message": "failed call"}},
        {"match_phrase": {"message": "CRITICAL"}}
      ]}}
    ],
    "must_not": [{"match_phrase": {"message": "valstats"}}]
  }},
  "_source": ["@timestamp", "message", "kubernetes.container_name", "kubernetes.pod_name"]
}'
```

## Gotchas and Noise Filters

| Issue | Solution |
|-------|----------|
| `response_code` is string, not int | Use `response_code.keyword` with string values `"500"` not `500` |
| `kubernetes.container_name` is already keyword type | Do NOT use `.keyword` suffix — use field name directly |
| `valstats` JSON lines match "error" | Add `must_not: match_phrase "valstats"` to exclude stats reporting |
| CloudWatch agent logs contain `container_last_termination_reason: "Error"` | Filter by specific container names to exclude infra noise |
| TensorFlow deprecation warnings flood results | These are benign startup noise — `WARNING tensorflow` and `PythonDeprecationWarning` |
| `failed call to cuInit: UNKNOWN ERROR (303)` | Expected on CPU-only nodes (no GPU), harmless |
| Aggregation returns empty buckets | Check field mapping — keyword fields don't need `.keyword`, text fields do |

## Valuation Container Names

| Container | Purpose |
|-----------|---------|
| `valuation-api` | Main ML API (internal traffic) |
| `valuation-api-batch` | Batch processing API |
| `valuation-batch` | Batch job runner |
| `valuation-auth` | Auth service |
| `valuation-frontend` | React web UI |
| `rate-limiter` | Rate limiting sidecar |
| `cluster-autoscaler` | K8s autoscaler (infra, usually noise) |
| `cloudwatch-agent` | Metrics collection (infra, usually noise) |

## Helper Script Reference

`ess-query.sh` is located at `~/.claude/skills/ess-error-search/ess-query.sh` and reads `~/essp_creds_<cluster>` by default:

```bash
~/.claude/skills/ess-error-search/ess-query.sh valuation nginx 24 502          # Valuation nginx 502s, last 24h
~/.claude/skills/ess-error-search/ess-query.sh valuation valuation-api 24 ERROR # Valuation app errors, last 24h
~/.claude/skills/ess-error-search/ess-query.sh atlas ans-auth 1 timeout         # Atlas-AI auth timeouts, last 1h
~/.claude/skills/ess-error-search/ess-query.sh atlas '*' 24 ERROR               # Atlas-AI all services, last 24h
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| No results | Check index name with `_cat/indices`, verify time range, broaden query |
| Auth failed | Check `~/essp_creds_<cluster>` exists and has correct credentials; re-fetch from Secrets Manager if password rotated |
| Slow queries | Add time range filter, use specific index (not wildcard), reduce `size` |
| 0 shards searched | Index pattern doesn't match any indices — list indices first |
| Empty aggregation buckets | Field type mismatch — check `_mapping/field/FIELDNAME` |
