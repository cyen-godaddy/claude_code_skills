---
name: kube-deploy
description: Deploy Kubernetes resources to Valuation EKS clusters. Use when deploying, updating, or troubleshooting deployments across dev/test/prod environments and regions.
---

# Kubernetes Deployment Skill

## When to Use
- Deploying a single resource or full cluster
- Updating deployments after config/image changes
- Troubleshooting failed deployments
- Verifying deployment status

## Environment Matrix

| Environment | Region    | Cluster Type | Context ARN | Values File |
|------------|-----------|-------------|-------------|-------------|
| dev        | uswest    | int         | `arn:aws:eks:us-west-2:784524224934:cluster/valuation-int-green` | `values-dev-int-green.yaml` |
| dev        | uswest    | pub         | `arn:aws:eks:us-west-2:784524224934:cluster/valuation-pub-green` | `values-dev-pub-green.yaml` |
| test       | uswest    | int         | `arn:aws:eks:us-west-2:759135530883:cluster/valuation-int-green` | `values-test-uswest-int-green.yaml` |
| test       | uswest    | pub         | `arn:aws:eks:us-west-2:759135530883:cluster/valuation-pub-green` | `values-test-uswest-pub-green.yaml` |
| test       | useast    | int         | `arn:aws:eks:us-east-1:759135530883:cluster/valuation-int-green` | `values-test-useast-int-green.yaml` |
| test       | useast    | pub         | `arn:aws:eks:us-east-1:759135530883:cluster/valuation-pub-green` | `values-test-useast-pub-green.yaml` |
| prod       | uswest    | int         | `arn:aws:eks:us-west-2:169724148413:cluster/valuation-int-green` | `values-prod-uswest-int-green.yaml` |
| prod       | uswest    | pub         | `arn:aws:eks:us-west-2:169724148413:cluster/valuation-pub-green` | `values-prod-uswest-pub-green.yaml` |
| prod       | useast    | int         | `arn:aws:eks:us-east-1:169724148413:cluster/valuation-int-green` | `values-prod-useast-int-green.yaml` |
| prod       | useast    | pub         | `arn:aws:eks:us-east-1:169724148413:cluster/valuation-pub-green` | `values-prod-useast-pub-green.yaml` |

## Values File Naming

Pattern: `templates/values-{env}-{region}-{type}-green.yaml`

Common values (merged automatically):
- `templates/values-test-common.yaml` (shared across test regions)
- `templates/values-prod-common.yaml` (shared across prod regions)

## Deployment Commands

### Single Resource
Always check the AWS context is correct, run `aws sts get-caller-identity` If not, run valdev, valtest, valprod to assume the Deploy role.
Always switch to the target context before running deploy-single.sh or the script will fail.
For example:

```
aws eks update-kubeconfig --name valuation-int-green --region us-west-2
aws eks update-kubeconfig --name valuation-pub-green --region us-west-2
aws eks update-kubeconfig --name valuation-int-green --region us-east-1
aws eks update-kubeconfig --name valuation-pub-green --region us-east-1
```


```bash
./templates/deploy-single.sh templates/values-{env}-{region}-{type}-green.yaml {context_arn} templates/{phase}/{resource}.yaml
```

Dry run (add `-d`):
```bash
./templates/deploy-single.sh templates/values-{env}-{region}-{type}-green.yaml {context_arn} templates/{phase}/{resource}.yaml -d
```

## Deployment Phases (Order Matters)

1. `kube/` - Infrastructure (cert-manager, load-balancer-controller, fluentbit)
2. `1/` - ConfigMaps and RBAC
3. `2/` - Deployments (the actual services)
4. `services/` - Service definitions (ClusterIP)
5. `hpa/` - Horizontal Pod Autoscalers
6. `pdb/` - Pod Disruption Budgets
7. `addons/` - Additional cluster addons

## Verification Steps

After deploying, verify:

```bash
# Check pod status
kubectl --context {context_arn} get pods -n default

# Check rollout status for a specific deployment
kubectl --context {context_arn} rollout status deployment/{service-name} -n default

# Check events for errors
kubectl --context {context_arn} get events -n default --sort-by='.lastTimestamp' | tail -20

# Check logs
kubectl --context {context_arn} logs deployment/{service-name} -n default --tail=50
```

## Common Services
Valuation services use `default` namespace

| Service | Template Dir | Description |
|---------|-------------|-------------|
| valuation-api | `2/` | Core valuation API |
| valuation-api-batch | `2/` | Batch processing endpoints |
| valuation-auth | `2/` | Authentication service |
| valuation-batch | `2/` | Background batch processing |
| valuation-frontend | `2/` | Web interface |
| valuation-proxy | `2/` | API gateway/proxy |
| rate-limiter | `2/` | Rate limiting service |
| tokenizer | `2/` | Token management |

## Templating

Uses `gomplate` with datasource syntax:
```
{{ (datasource "d").path.to.value }}
```

Values files are merged with `yq eval-all` before being passed to gomplate.

## Safety Checklist

Before deploying to **test or prod**:
- [ ] Changes tested in dev first
- [ ] Dry run (`-d` flag) reviewed
- [ ] Correct context ARN for target environment
- [ ] Values file matches target environment
- [ ] No hardcoded secrets in templates

## Troubleshooting

- **Pods in CrashLoopBackOff**: Check logs, verify configmaps and secrets exist
- **ImagePullBackOff**: Verify image exists in ECR, check IAM permissions
- **Pending pods**: Check node capacity, resource requests/limits
- **Ingress not working**: May need second deploy-all.sh run; check ALB controller logs
