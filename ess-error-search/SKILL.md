---
name: ess-error-search
description: Use when searching for application errors, exceptions, or service failures in ESS/Elasticsearch logs. Triggers on phrases like "find errors", "check logs", "debug service", "look for failures in ESS".
---

# ESS Error Search

## Overview

Query the Atlas-AI Elastic Cloud cluster to find service errors and exceptions. The cluster stores logs from Katana-deployed services (ans-registry-poc, ans-auth, agent2agent, etc.).

## Quick Reference

| Item | Value |
|------|-------|
| Cluster | `https://91e8e2e1c24c4816b97eaa64847e3813.es.us-west-2.aws.found.io:9243` |
| Kibana | `https://1f69e876baa04d0d8ebfef9cb217e676.kb.us-west-2.aws.found.io:9243` |
| Auth | Basic auth `admin:<password>` |
| Creds | `essp_creds` file or AWS Secrets Manager `essp_deployment_credentials` |
| Index pattern | `.ds-logs-gdelastic.katana.{app}-{env}-*` |

## Log Structure

| Field | Description |
|-------|-------------|
| `@timestamp` | ISO 8601 timestamp |
| `message` | Raw log text (includes embedded timestamp, logger, level) |
| `container_name` | Service name (e.g., `ans-registry-poc`) |
| `KATANA_APP` | Katana application name |
| `KATANA_ENVIRONMENT` | Environment (prod, ote, test, dev-private) |
| `GD_ENV` | GoDaddy environment |
| `GD_REGION` | AWS region |

## Common Queries

### Find Recent Errors

```bash
ESS_URL="https://91e8e2e1c24c4816b97eaa64847e3813.es.us-west-2.aws.found.io:9243"
ESS_AUTH="admin:$(jq -r .ingestion_user_password essp_creds)"

curl -s -u "$ESS_AUTH" "$ESS_URL/.ds-logs-gdelastic.katana.ans-registry-poc-*,.ds-logs-gdelastic.katana.ans-auth-*/_search" \
  -H 'Content-Type: application/json' -d '{
  "size": 20,
  "sort": [{"@timestamp": "desc"}],
  "query": {"match_phrase": {"message": "ERROR"}}
}' | jq '.hits.hits[]._source | {ts: .["@timestamp"], app: .container_name, msg: .message[:300]}'
```

### Filter by Service and Time

```bash
curl -s -u "$ESS_AUTH" "$ESS_URL/.ds-logs-gdelastic.katana.ans-registry-poc-prod-*/_search" \
  -H 'Content-Type: application/json' -d '{
  "size": 50,
  "sort": [{"@timestamp": "desc"}],
  "query": {
    "bool": {
      "must": [{"match_phrase": {"message": "ERROR"}}],
      "filter": [{"range": {"@timestamp": {"gte": "now-1h"}}}]
    }
  }
}' | jq '.hits.hits[]._source.message'
```

### Search for Specific Exception

```bash
curl -s -u "$ESS_AUTH" "$ESS_URL/.ds-logs-gdelastic.katana.ans-registry-poc-*,.ds-logs-gdelastic.katana.ans-auth-*/_search" \
  -H 'Content-Type: application/json' -d '{
  "size": 20,
  "query": {
    "bool": {
      "must": [
        {"match_phrase": {"message": "ConnectionTimeout"}},
        {"match_phrase": {"message": "sso.godaddy.com"}}
      ]
    }
  }
}' | jq '.hits.hits[]._source.message'
```

### Count Errors by Service (Last 24h)

```bash
curl -s -u "$ESS_AUTH" "$ESS_URL/.ds-logs-gdelastic.katana.ans-registry-poc-*,.ds-logs-gdelastic.katana.ans-auth-*/_search" \
  -H 'Content-Type: application/json' -d '{
  "size": 0,
  "query": {
    "bool": {
      "must": [{"match": {"message": "ERROR"}}],
      "filter": [{"range": {"@timestamp": {"gte": "now-24h"}}}]
    }
  },
  "aggs": {
    "by_service": {"terms": {"field": "container_name", "size": 20}}
  }
}' | jq '{total: .hits.total.value, by_service: .aggregations.by_service.buckets}'
```

## Target Services

Only two services are monitored:

| Service | Index Pattern | Description |
|---------|---------------|-------------|
| `ans-registry-poc` | `.ds-logs-gdelastic.katana.ans-registry-poc-*` | ANS Registry API |
| `ans-auth` | `.ds-logs-gdelastic.katana.ans-auth-*` | Auth service |

**Combined index for both:**
```
.ds-logs-gdelastic.katana.ans-registry-poc-*,.ds-logs-gdelastic.katana.ans-auth-*
```

## Error Patterns to Search

| Pattern | Meaning |
|---------|---------|
| `ERROR` | Application error level logs |
| `Exception` | Java/Kotlin stack traces |
| `failed` | Operation failures |
| `timeout` | Connection/request timeouts |
| `refused` | Connection refused |
| `unauthorized` | Auth failures (401) |
| `forbidden` | Permission denied (403) |

## Helper Script

Use `ess-query.sh` for quick lookups:

```bash
# Usage: ./ess-query.sh [service] [hours] [pattern]
CREDS_FILE=path/to/essp_creds ./ess-query.sh '*' 24 ERROR      # All services, last 24h
CREDS_FILE=path/to/essp_creds ./ess-query.sh ans-auth 1 timeout # Auth service, last 1h, timeouts
```

## Troubleshooting

**No results?**
- Check index pattern matches actual indices (`_cat/indices?v`)
- Verify time range includes data
- Try broader query (remove filters)

**Auth failed?**
- Refresh credentials from `essp_creds` or Secrets Manager
- Check password hasn't rotated

**Slow queries?**
- Add time range filter
- Use specific index instead of wildcard
- Reduce `size` parameter
