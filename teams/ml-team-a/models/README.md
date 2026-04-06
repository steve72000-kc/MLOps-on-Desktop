# Team A Models

This folder defines the Team A deployment child app (`ml-team-a-deployments`).

Current deployment source of truth:
- `apps/tenants/ml-team-a/deployments/`
- workflow writes per-model manifests as `<intent-name>.yaml`
- KServe `InferenceService` resources are reconciled in namespace `ml-team-a`
- model version label is workflow-managed (`platform.ai-ml/model-version`) from resolved MLflow alias
- stale workflow-managed files are pruned when models are no longer discovered for the polled alias

## MLflow Alias Sync Flow

Current scheduled flow:
1. Team updates model-version intent tags and the `champion` alias in MLflow.
2. Central hub CronWorkflow (`infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`) dispatches tenant workflows from `ClusterWorkflowTemplate/mlflow-tag-sync`.
3. Workflow resolves alias + intent JSON from MLflow model version tags.
4. Workflow validates + writes manifest to `apps/tenants/ml-team-a/deployments/<intent-name>.yaml`.
5. Hub also dispatches `ClusterWorkflowTemplate/mlflow-tag-prune` with active model list.
6. Prune removes stale workflow-managed manifests + kustomization entries when models are no longer discovered.
7. `ml-team-a-deployments` Argo CD app reconciles cluster state from Git.

Notes:
- workflow templates support challenger mode, but current hub cron profile polls `champion` only
- rendered manifests intentionally omit `platform.ai-ml/trace-id`, so unchanged poll cycles avoid synthetic revision churn
- if hub discovery returns `[]`, sync dispatch is skipped and only prune runs for that tenant poll
- if you need to remove a stale deployment after backing artifact reset, remove it from
  `apps/tenants/ml-team-a/deployments/`

## Service Endpoint Discovery

KServe/Knative publishes the live URL in `InferenceService.status.url`.

```bash
MODEL_NAME="${MODEL_NAME:-xgboost-synth-v1}" # default training-script name
kubectl -n ml-team-a get inferenceservice "${MODEL_NAME}" -o jsonpath='{.status.url}{"\n"}'
```

With platform domain config applied, predictor hosts follow:
- `http://<model-name>-predictor.ml-team-a.ai-ml.local`

Ingress IP in this repo is typically:
- `172.29.0.203` (`istio-ingressgateway`)

## Bash Test Commands

### 1) Verify readiness

```bash
MODEL_NAME="${MODEL_NAME:-xgboost-synth-v1}"
kubectl -n ml-team-a get inferenceservice "${MODEL_NAME}"
kubectl -n ml-team-a wait --for=condition=Ready "inferenceservice/${MODEL_NAME}" --timeout=180s
```

If readiness stalls:

```bash
kubectl -n ml-team-a describe inferenceservice "${MODEL_NAME}" | rg -n 'exceeded quota|ServerlessModeRejected|InternalError'
```

Team-a quota note:
- `teams/ml-team-a/resourcequota.yaml` defines a larger quota profile, but it is currently commented out in `teams/ml-team-a/kustomization.yaml`
- if you enable it, include this check:

```bash
kubectl -n ml-team-a describe resourcequota tenant-quota
```

### 2) Verify Knative domain config

```bash
kubectl -n knative-serving get configmap config-domain -o yaml | rg -n 'ai-ml.local'
```

### 3) Resolve endpoint details

```bash
MODEL_NAME="${MODEL_NAME:-xgboost-synth-v1}"
MODEL_URL="$(kubectl -n ml-team-a get inferenceservice "${MODEL_NAME}" -o jsonpath='{.status.url}')"
MODEL_HOST="${MODEL_URL#http://}"
MODEL_HOST="${MODEL_HOST#https://}"
INGRESS_IP="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

echo "MODEL_NAME=$MODEL_NAME"
echo "MODEL_URL=$MODEL_URL"
echo "MODEL_HOST=$MODEL_HOST"
echo "INGRESS_IP=$INGRESS_IP"
```

### 4) Smoke test through ingress mesh

Use `Host` header routing directly to ingress IP:

```bash
curl -i "http://${INGRESS_IP}/v2/health/ready" \
  -H "Host: ${MODEL_HOST}"
```

Optional inference example (works for default 4-feature demo models):

```bash
curl -s "http://${INGRESS_IP}/v2/models/${MODEL_NAME}/infer" \
  -H "Host: ${MODEL_HOST}" \
  -H "Content-Type: application/json" \
  -d '{"inputs":[{"name":"predict","shape":[1,4],"datatype":"FP32","data":[[6.8,2.8,4.8,1.4]]}]}' | jq .
```

### 5) Optional hosts-file convenience

If you prefer calling by hostname (without `Host` header), add:

```bash
echo "${INGRESS_IP} ${MODEL_HOST}" | sudo tee -a /etc/hosts
```

Then call:

```bash
curl -i "http://${MODEL_HOST}/v2/health/ready"
```

### 6) If ingress returns 404

```bash
kubectl -n ml-team-a get ksvc "${MODEL_NAME}-predictor" -o jsonpath='{.status.url}{"\n"}'
kubectl -n ml-team-a get inferenceservice "${MODEL_NAME}" -o jsonpath='{.status.url}{"\n"}'
```

If either URL still ends with `.svc.cluster.local`, Knative domain config has not reconciled yet.
After syncing `knative-serving-core`, trigger a fresh predictor route:

```bash
kubectl -n ml-team-a delete ksvc "${MODEL_NAME}-predictor"
```

KServe recreates the predictor service and picks up current domain config.
