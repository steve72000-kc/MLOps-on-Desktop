# Team A MLflow

`teams/ml-team-a/mlflow/` defines the Team-a MLflow application, persistence,
artifact-store credentials, and mesh host routing.

## Files

- `application.yaml` defines the Argo CD child application `mlflow-ml-team-a`
- `kustomization.yaml` is the Team-a MLflow composition entrypoint
- `values.yaml` contains the Team-a Helm values overlay
- `pvc.yaml` defines the sqlite persistence claim `mlflow-data`
- `secret-s3-credentials.yaml` defines the Team-a MinIO artifact credentials
- `virtualservice-mlflow.yaml` defines the mesh host route

## Host And Ingress

### MLflow Host

Read the Team-a MLflow host from the `VirtualService`.

```bash
MLFLOW_HOST="$(kubectl -n ml-team-a get virtualservice mlflow -o jsonpath='{.spec.hosts[0]}')"
echo "$MLFLOW_HOST"
```

Current Team-a host:

- `mlflow.ml-team-a.local`

### Ingress IP

```bash
INGRESS_IP="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "$INGRESS_IP"
```

### Mesh Reachability

```bash
curl -i "http://${INGRESS_IP}/health" \
  -H "Host: ${MLFLOW_HOST}"
```

```bash
curl -s "http://${INGRESS_IP}/api/2.0/mlflow/experiments/list" \
  -H "Host: ${MLFLOW_HOST}" | jq .
```

## Storage Wiring

- sqlite database path: `/mlflow/data/mlflow.db`
- sqlite PVC: `mlflow-data`
- Team-a PVC binds to infra PV `mlflow-ml-team-a-pv`
- artifact root: `s3://mlflow-ml-team-a/artifacts`
- MinIO endpoint: `http://minio.minio.svc.cluster.local:9000`

### Quick Checks

```bash
kubectl -n ml-team-a get pvc mlflow-data
kubectl -n ml-team-a get secret mlflow-s3-credentials
kubectl -n ml-team-a get pod -l app.kubernetes.io/name=mlflow
```

## Training Helpers

These scripts default to `http://mlflow.ml-team-a.local` and are intended for
mesh-host access from a shell environment.

### Sklearn Champion Script

Script:

- `teams/ml-team-a/mlflow/scripts/train_and_promote_champion.py`

Run:

```bash
python3 teams/ml-team-a/mlflow/scripts/train_and_promote_champion.py
```

Optional explicit URI override:

```bash
python3 teams/ml-team-a/mlflow/scripts/train_and_promote_champion.py \
  --tracking-uri http://mlflow.ml-team-a.local
```

If the local environment has an MLflow/protobuf conflict:

```bash
pip install --upgrade 'mlflow==2.22.0' 'protobuf<4,>=3.20.3' scikit-learn joblib
```

Temporary protobuf workaround:

```bash
PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python \
python3 teams/ml-team-a/mlflow/scripts/train_and_promote_champion.py
```

If MLflow auth is enabled in another environment:

```bash
export MLFLOW_TRACKING_USERNAME="<username>"
export MLFLOW_TRACKING_PASSWORD="<password>"
python3 teams/ml-team-a/mlflow/scripts/train_and_promote_champion.py
```

Behavior:

- trains a small sklearn iris KNN model
- logs a native joblib model artifact to MLflow
- creates a new model version for `prod.ml-team-a.sklearn-iris`
- sets `kserve.intent.mode=inline`
- sets `kserve.intent.payload=<json>`
- derives `storageUri` from the MinIO-backed MLflow artifact path
- points alias `champion` to the new version

The shared sync hub then discovers the alias and intent tags and writes the
corresponding GitOps manifest.

### XGBoost Champion Script

Script:

- `teams/ml-team-a/mlflow/scripts/train_xgboost_and_promote_champion.py`

Run:

```bash
python3 teams/ml-team-a/mlflow/scripts/train_xgboost_and_promote_champion.py
```

If needed, install dependencies:

```bash
pip install --upgrade 'mlflow==2.22.0' 'protobuf<4,>=3.20.3' xgboost numpy
```

Behavior:

- trains a synthetic multiclass CPU-only XGBoost model
- logs a native XGBoost artifact to MLflow
- creates a new model version for `prod.ml-team-a.xgboost-synth`
- sets `kserve.intent.mode=inline`
- sets `kserve.intent.payload=<json>` with:
  - `modelFormat.name=xgboost`
  - `runtime=kserve-mlserver-custom`
  - `storageUri=s3://...`
- points alias `champion` to the new version

Optional overrides:

```bash
python3 teams/ml-team-a/mlflow/scripts/train_xgboost_and_promote_champion.py \
  --registered-model prod.ml-team-a.xgboost-synth \
  --kserve-name xgboost-synth-v1 \
  --minio-artifact-root s3://mlflow-ml-team-a/artifacts
```

The deployment URL is later published back to the model version as
`gitops.sync.url`.

## Deployment Validation

After the sync workflow runs and Argo CD applies the rendered manifest, validate
the live `InferenceService`.

### Wait For Readiness

```bash
MODEL_NAME="${MODEL_NAME:-xgboost-synth-v1}"
kubectl -n ml-team-a wait --for=condition=Ready "inferenceservice/${MODEL_NAME}" --timeout=180s
```

### Ingress Readiness Check

```bash
MODEL_URL="$(kubectl -n ml-team-a get inferenceservice "${MODEL_NAME}" -o jsonpath='{.status.url}')"
MODEL_HOST="${MODEL_URL#http://}"; MODEL_HOST="${MODEL_HOST#https://}"
INGRESS_IP="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

curl -i "http://${INGRESS_IP}/v2/health/ready" \
  -H "Host: ${MODEL_HOST}"
```

### Optional Inference Check

```bash
curl -s "http://${INGRESS_IP}/v2/models/${MODEL_NAME}/infer" \
  -H "Host: ${MODEL_HOST}" \
  -H "Content-Type: application/json" \
  -d '{"inputs":[{"name":"predict","shape":[1,4],"datatype":"FP32","data":[[6.8,2.8,4.8,1.4]]}]}' | jq .
```

## Hosts File Convenience

```bash
echo "${INGRESS_IP} ${MLFLOW_HOST}" | sudo tee -a /etc/hosts
```

```bash
curl -i "http://${MLFLOW_HOST}/health"
```

## Troubleshooting

### `404` Through Ingress

- verify the host from the `VirtualService` and send that exact `Host` header
- inspect the `VirtualService` directly:

```bash
kubectl -n ml-team-a get virtualservice mlflow -o yaml
```

### Connect Failure

- inspect the ingress gateway service and load balancer IP:

```bash
kubectl -n istio-system get svc istio-ingressgateway -o wide
```

### Missing Argo CD Child App

```bash
kubectl apply -f teams/ml-team-a/mlflow/application.yaml
kubectl -n argocd annotate application ml-team-a-root argocd.argoproj.io/refresh=hard --overwrite
```

## Sync Tag Visibility

When workflows update model-version tags quickly (`accepted` -> `rendered` ->
`applied`), the MLflow UI can lag behind the API.

Use the API as source of truth:

```bash
MLFLOW_TRACKING_URI="${MLFLOW_TRACKING_URI:-http://mlflow.ml-team-a.local}" python3 - <<'PY'
import os
from mlflow import MlflowClient

client = MlflowClient(tracking_uri=os.environ["MLFLOW_TRACKING_URI"])
alias = "champion"
team_prefix = "prod.ml-team-a."
tag_keys = [
    "gitops.sync.status",
    "gitops.sync.reason",
    "gitops.sync.commit",
    "gitops.sync.url",
    "gitops.sync.trace_id",
    "gitops.sync.updated_at",
]

models = sorted(
    rm.name
    for rm in client.search_registered_models()
    if rm.name.startswith(team_prefix)
)

if not models:
    print("no Team-a registered models found")

for model in models:
    try:
        mv = client.get_model_version_by_alias(model, alias)
    except Exception as exc:
        print(model, "->", exc)
        continue
    print("\nmodel:", model, "version:", mv.version)
    for key in tag_keys:
        print(" ", key, "=", mv.tags.get(key))
PY
```

If UI and API disagree:

1. Hard-refresh the browser tab.
2. Re-open the model version page.
3. Re-check the `finalize-status` pod logs for the last workflow run.

No-op sync behavior:

- hub polls can still update `gitops.sync.trace_id` and
  `gitops.sync.updated_at` in MLflow
- unchanged alias and intent state should not rewrite
  `apps/tenants/.../deployments/<intent-name>.yaml`
- expected unchanged writeback outcome: `writeback_status=noop`, reason
  `no_diff`

Expected final success state:

- `gitops.sync.status=applied`
- `gitops.sync.reason=applied`
- `gitops.sync.commit=<sha>`
- `gitops.sync.url=<inference URL>`
