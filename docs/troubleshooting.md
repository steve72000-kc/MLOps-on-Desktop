# Troubleshooting

## Cluster fails to create

- Verify Docker is running: `docker info`
- Remove stale cluster: `./bootstrap/uninstall.sh`

## `kubectl` API calls fail with `Unable to connect to the server: EOF`

Symptom:
- `kubectl cluster-info` returns `EOF`.

Typical cause:
- Kind control plane instability, often after host disk pressure/full-disk conditions.

Checks:
- `kubectl config current-context`
- `kubectl cluster-info`
- `docker ps --format 'table {{.Names}}\t{{.Status}}' | rg kind`

Recovery:
- Restart control plane container:
  - `docker restart kind-aiml-control-plane`
- If kubeconfig endpoint is stale:
  - `kind export kubeconfig --name aiml`
- If cluster is unrecoverable:
  - `./bootstrap/uninstall.sh && ./bootstrap/install.sh`

## LoadBalancer `EXTERNAL-IP` pending

- Check MetalLB controller: `kubectl -n metallb-system get pods`
- Confirm address pool exists: `kubectl -n metallb-system get ipaddresspool,l2advertisement`
- Check service events:
  - `kubectl -n <ns> describe svc <name>`
- Override pool manually if needed:
  - `METALLB_RANGE=172.18.255.200-172.18.255.220 ./bootstrap/install.sh`

## Promtail `too many open files`

Symptoms:
- Promtail logs include:
  - `failed to make file target manager: too many open files`

Why:
- This is typically Kind/Docker runtime file-descriptor pressure, not a Promtail parser bug.
- High pod/log churn (for example many workflow pods) amplifies it.

Checks:
- verify promtail status:
  - `kubectl -n monitoring get pods -l app.kubernetes.io/name=promtail -o wide`
- inspect node process limits in Kind containers:
  - `for n in $(kind get nodes --name aiml); do echo "== $n =="; docker exec "$n" sh -lc 'for p in containerd kubelet; do pid=$(pidof $p | awk "{print \\$1}" || true); [ -n "$pid" ] && awk "/Max open files/ {print $0}" /proc/$pid/limits; done'; done`

Current repo behavior:
- `bootstrap/install.sh` applies best-effort Kind node tuning inside node containers:
  - env var: `KIND_NODE_NOFILE_LIMIT` (default `1048576`)
  - env var: `KIND_NODE_INOTIFY_MAX_USER_INSTANCES` (default `4096`)
  - env var: `KIND_NODE_INOTIFY_MAX_USER_WATCHES` (default `1048576`)

Recreate with explicit limits:
- `KIND_NODE_NOFILE_LIMIT=1048576 KIND_NODE_INOTIFY_MAX_USER_INSTANCES=4096 KIND_NODE_INOTIFY_MAX_USER_WATCHES=1048576 ./bootstrap/install.sh`

Patch a running cluster without recreate (best-effort):
- `for n in $(kind get nodes --name aiml); do docker exec "$n" sh -lc 'for p in containerd kubelet; do pid=$(pidof $p | awk "{print \\$1}" || true); [ -n "$pid" ] && prlimit --pid "$pid" --nofile=1048576:1048576; done'; done`

Also tune inotify limits (often the real source of `too many open files` from log watchers):
- `for n in $(kind get nodes --name aiml); do docker exec "$n" sh -lc 'sysctl -w fs.inotify.max_user_instances=4096; sysctl -w fs.inotify.max_user_watches=1048576; sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches'; done`

Verify inotify values inside Kind nodes:
- `for n in $(kind get nodes --name aiml); do echo "== $n =="; docker exec "$n" sh -lc 'sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches'; done`

## Monitoring app is not healthy

Symptoms:
- Argo app `monitoring` is `OutOfSync` or `Degraded`.

Checks:
- `kubectl -n argocd get application monitoring -o wide`
- `kubectl -n argocd describe application monitoring`
- `kubectl -n monitoring get pods`

Common fix:
- force hard refresh and resync:
  - `kubectl -n argocd annotate application monitoring argocd.argoproj.io/refresh=hard --overwrite`
- if chart pull failed, retry after network stabilizes.

## Grafana is unreachable

Checks:
- direct LB service:
  - `kubectl -n monitoring get svc kube-prometheus-stack-grafana`
- host route VirtualService:
  - `kubectl -n monitoring get virtualservice grafana -o yaml`
- ingress gateway address:
  - `kubectl -n istio-system get svc istio-ingressgateway`

Fixes:
- verify `EXTERNAL-IP` was assigned (`172.29.0.205` expected by default).
- verify `/etc/hosts` contains ingress mapping for `grafana.platform.local` when using host route.
- verify Grafana pod is running:
  - `kubectl -n monitoring get pods -l app.kubernetes.io/name=grafana`

## Grafana has no logs in Loki views

Checks:
- `kubectl -n monitoring get pods -l app.kubernetes.io/name=promtail`
- `kubectl -n monitoring get svc loki`
- promtail errors:
  - `kubectl -n monitoring logs daemonset/promtail --tail=200`

Fixes:
- confirm promtail client URL resolves:
  - `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`
- if promtail readiness probe stays `500`, check Loki readiness first:
  - `kubectl -n monitoring get pods -l app.kubernetes.io/name=loki`
  - `kubectl -n monitoring logs statefulset/loki --tail=200`
- restart promtail daemonset:
  - `kubectl -n monitoring rollout restart daemonset/promtail`

## Prometheus targets are down

Checks:
- `kubectl -n monitoring get servicemonitor`
- `kubectl -n monitoring get podmonitors`
- `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090`
- open `http://localhost:9090/targets`

Fixes:
- confirm metric services exist:
  - `kubectl -n argocd get svc argocd-metrics argocd-server-metrics argocd-repo-server`
  - `kubectl -n argo get svc workflow-controller-metrics`
- resync monitoring app after service/CRD reconciliation:
  - `kubectl -n argocd annotate application monitoring argocd.argoproj.io/refresh=hard --overwrite`

## MinIO PVC remains Pending

- Check PV/PVC state:
  - `kubectl get pv minio-pv`
  - `kubectl -n minio get pvc minio-pvc`
- Confirm MinIO path exists inside Kind nodes:
  - `docker exec -it kind-aiml-control-plane ls -la /var/local/minio-data`
- Ensure `bootstrap/install.sh` completed with MinIO bind mount creation.

## MinIO pod cannot write data directory

- Check pod events/logs:
  - `kubectl -n minio describe pod -l app.kubernetes.io/name=minio`
- Ensure host path permissions are permissive for local dev:
  - `ls -ld .local .local/minio-data .local/minio-data/minio`
- Re-apply permissive mode if needed:
  - `chmod 0777 .local/minio-data .local/minio-data/minio`
- If `.local` is owned by root after a prior `sudo` reset, restore it before reinstalling:
  - `sudo chown -R "$(id -un):$(id -gn)" .local`

## Gitea PVC remains Pending

- Check PV/PVC state:
  - `kubectl get pv gitea-shared-storage-pv`
  - `kubectl -n gitea get pvc gitea-shared-storage`
- Confirm Gitea path exists inside Kind nodes:
  - `docker exec -it kind-aiml-control-plane ls -la /var/local/gitea-data`
- Ensure `bootstrap/install.sh` completed with Gitea bind mount creation.

## Gitea pod cannot write data directory

- Check pod events/logs:
  - `kubectl -n gitea describe pod -l app.kubernetes.io/name=gitea`
- Ensure host path permissions are permissive for local dev:
  - `ls -ld .local/gitea-data .local/gitea-data/gitea`
- Re-apply permissive mode if needed:
  - `chmod 0777 .local/gitea-data .local/gitea-data/gitea`

## Argo CD login

- Username: `admin`
- Password:
  - `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`

## GitOps init fails on SSH push

- Confirm local SSH key exists:
  - `ls ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub`
- Override key path if needed:
  - `GITEA_SSH_PUBLIC_KEY_PATH=/path/to/key.pub ./bootstrap/install.sh`
- Verify remote URL:
  - `git remote -v | grep gitea`

## Gitea SSH host key changed after cluster rebuild

Symptom:
- `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`
- `Host key verification failed.` when talking to `172.29.0.202`.

Fix:
- `ssh-keygen -f ~/.ssh/known_hosts -R 172.29.0.202`
- reconnect/pull/push once to trust the new key

## GitOps init fails on Gitea authentication

- Verify configured bootstrap admin credentials:
  - `echo "$GITEA_ADMIN_USERNAME"`
- Rerun install with explicit values:
  - `GITEA_ADMIN_USERNAME=gitops-admin GITEA_ADMIN_PASSWORD=gitops123 ./bootstrap/install.sh`

## Git push went to Gitea instead of GitHub/Codeberg

Bootstrap preserves your existing `origin` remote but makes the current branch
track the in-cluster `gitea/<branch>` remote, because that is the repo Argo CD
and workflow writeback reconcile against.

- Check current remotes:
  - `git remote -v`
- Check the current branch upstream:
  - `git branch -vv | sed -n '/^*/p'`
- Push back to your original clone source explicitly:
  - `git push origin $(git rev-parse --abbrev-ref HEAD)`
- If you want the current branch to track `origin` again after pushing there:
  - `git branch --set-upstream-to origin/$(git rev-parse --abbrev-ref HEAD) $(git rev-parse --abbrev-ref HEAD)`

## Team root apps missing or stale

- Confirm team root apps exist:
  - `kubectl -n argocd get applications | rg "ml-team-a-root|ml-team-b-root"`
- Refresh root app:
  - `kubectl -n argocd annotate application ai-ml-root argocd.argoproj.io/refresh=hard --overwrite`
- Refresh team app:
  - `kubectl -n argocd annotate application ml-team-a-root argocd.argoproj.io/refresh=hard --overwrite`

## Child app missing after interrupted sync (`mlflow-ml-team-a`)

Symptom:
- Argo UI: `Resource not found in cluster: argoproj.io/v1alpha1/Application:mlflow-ml-team-a`.

Recovery:
- recreate app manifest directly:
  - `kubectl apply -f teams/ml-team-a/mlflow/application.yaml`
- then refresh parent:
  - `kubectl -n argocd annotate application ml-team-a-root argocd.argoproj.io/refresh=hard --overwrite`

## `istio-ingressgateway` service is missing

Symptom:
- `kubectl -n istio-system get svc istio-ingressgateway` returns `NotFound`.

Checks:
- Confirm `istio-ingressgateway` Argo app exists and is synced.
- Confirm chart deployment/service:
  - `kubectl -n istio-system get deploy,svc | rg ingressgateway`

## Istio gateway Argo `ComparisonError` on schema validation

Symptom:
- Argo error: `additional properties 'service', 'autoscaling', 'replicaCount' not allowed`.

Current repo config:
- `infra/istio/application-ingressgateway.yaml` uses:
  - Helm `parameters` (instead of inline values)
  - `skipSchemaValidation: true`

If still failing:
- Root cause is usually Argo's bundled Helm not honoring `skipSchemaValidation` for this Istio chart/schema combo.
- Short-term workaround for demos:
  - remove `service/autoscaling/replicaCount` Helm parameters from the Argo app
  - sync the app
  - patch the generated service/deployment manually
- Long-term fix:
  - upgrade Argo CD/Helm bundle and re-enable Helm parameters in GitOps.

## KServe sync fails on webhook connection or CRD annotation size

Symptoms:
- `failed calling webhook ... kserve-webhook-server.validator ... connection refused`
- `CustomResourceDefinition ... metadata.annotations: Too long`

Checks:
- `kubectl -n kserve get pods,svc`
- `kubectl -n argocd get application kserve -o yaml | rg -n "retry|ServerSideApply|ignoreDifferences"`

Current repo settings:
- single Argo app installs `kserve-crd` then `kserve`
- sync retries are enabled
- `ServerSideApply=true` is enabled
- mutating webhook `caBundle` and `failurePolicy` diffs are ignored

If webhook errors persist:
- wait for `kserve-webhook-server` readiness and resync
- optionally disable default ServingRuntime installs in `infra/kserve/application.yaml` (block is present and commented)

## `ServerlessModeRejected` for InferenceService

Symptom:
- `It is not possible to use Knative deployment mode when Knative Services are not available`.

Checks:
- `kubectl get crd services.serving.knative.dev`
- `kubectl -n knative-serving get pods,deploy`
- `kubectl -n argocd get applications | rg 'knative|kserve'`

If Knative is healthy:
- restart KServe controller once:
  - `kubectl -n kserve rollout restart deploy/kserve-controller-manager`

## MLflow CrashLoop with `ExitCode 137`

Symptom:
- Pod restarts with `Exit Code: 137` and readiness/liveness failures.

Typical cause:
- OOM kill from too many gunicorn workers for laptop profile.

Checks:
- `kubectl -n ml-team-a describe pod <mlflow-pod>`
- `kubectl -n ml-team-a logs <mlflow-pod> -c mlflow --previous`

Fix used in repo:
- `infra/mlflow/base/values.yaml` sets:
  - `extraArgs.workers: "1"` (string, not number)

## MLflow PVC remains Pending

Symptoms:
- MLflow pod cannot schedule and PVC is `Pending`.

Checks:
- `kubectl -n ml-team-a get pvc mlflow-data`
- `kubectl get pv | rg mlflow-ml-team-a-pv`
- `docker exec -it kind-aiml-control-plane ls -la /var/local/minio-data/mlflow/ml-team-a`

Fixes:
- ensure infra PV exists (`infra/mlflow/pv-ml-team-a.yaml`)
- ensure team PVC exists (`teams/ml-team-a/mlflow/pvc.yaml`)
- rerun bootstrap if host bind mount directory is missing.

## MLflow artifact upload/download fails against MinIO

Symptoms:
- MLflow API works but artifact operations return S3 auth/connection errors.

Checks:
- `kubectl -n ml-team-a get secret mlflow-s3-credentials -o yaml`
- `kubectl -n ml-team-a logs deploy/mlflow | rg -i \"s3|artifact|access denied|signature\"`
- `kubectl -n minio logs deploy/minio`

Fixes:
- resync `minio` Argo app to re-run bootstrap hook job:
  - `kubectl -n argocd annotate application minio argocd.argoproj.io/refresh=hard --overwrite`
- verify the role-specific NetworkPolicy still allows the affected pod class to
  reach `minio` on TCP `9000`:
  - `mlflow-egress-minio`
  - `workflow-egress-minio`
  - `serving-runtime-egress-minio`
- verify secret values:
  - `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `MLFLOW_S3_ENDPOINT_URL`.

## MLflow Argo `ComparisonError` on `extraArgs.workers`

Symptom:
- `at '/extraArgs/workers': got number, want string`.

Fix:
- Quote value in Helm values:
  - `workers: "1"`

## MLflow probe failures with Istio sidecar

Symptom:
- Startup/readiness/liveness intermittently fail through sidecar health endpoints.

Checks:
- `kubectl -n ml-team-a describe pod <mlflow-pod>`
- `kubectl -n ml-team-a get events --sort-by=.lastTimestamp | tail -n 40`

Fixes used in repo:
- Relaxed probe timing in `infra/mlflow/base/values.yaml`.
- tenant baseline policy allows only `istio-system/app=istiod` control-plane
  egress and `mlflow-allow-ingress-mesh` keeps MLflow reachable from
  `istio-ingressgateway` pods.

## MLflow tag-sync workflow appears "stuck" in `Running`

Symptoms:

- Workflow phase remains `Running`.
- Many nodes already show `Succeeded`.
- Logs look repetitive or empty when querying label selectors.

What usually happens:

- The workflow is not stuck; a later node (often `writeback` or `finalize`) is still pending/initializing.
- `PodInitializing` is expected briefly, especially with Istio sidecar startup.

Checks:

```bash
WF="$(kubectl -n ml-team-a get wf --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name --no-headers | tail -n 1)"

kubectl -n ml-team-a get wf "$WF" -o json | jq -r '
  .status.phase as $p |
  .status.message as $m |
  "workflow_phase=\($p)\nworkflow_message=\($m)\n",
  (.status.nodes | to_entries[] |
    [.value.displayName, .value.phase, (.value.templateName // ""), (.value.message // "")]
    | @tsv)
'

kubectl -n ml-team-a get pods -l workflows.argoproj.io/workflow="$WF" --sort-by=.metadata.creationTimestamp
```

Then inspect the active pod by node name (do not hardcode stale pod names from previous workflow runs):

```bash
for p in $(kubectl -n ml-team-a get pods -l workflows.argoproj.io/workflow="$WF" -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $p (main) ==="
  kubectl -n ml-team-a logs "$p" -c main --tail=200 || true
done
```

## Writeback fails with `Remote branch ... not found`

Symptom:

- Writeback logs contain:
  - `warning: Could not find remote branch ... to clone`
  - `fatal: Remote branch ... not found in upstream origin`

Cause:

- Branch mismatch between workflow arg (`git_default_branch`) and remote repo default branch.

Fix:

- Keep branch sources aligned. The checked-in repo now uses `auto`, which
  resolves the remote default branch from Gitea `HEAD`:
  - `infra/argo-workflows/templates/mlflow-tag-sync-workflow.yaml`
  - `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`
  - `teams/<team>/tenant-config.yaml`
  - `teams/<team>/workflows/secret-mlflow-sync-git-credentials.yaml`
  - `infra/argo-workflows/scripts/git_writeback.sh` fallback
  - `infra/argo-workflows/scripts/git_prune_manifests.sh` fallback
- If remote `HEAD` drifted from the branch you want the platform to follow,
  rerun:
  - `./bootstrap/gitops-init.sh`
  - this now re-pushes the current branch, reconciles the Gitea repo default
    branch, and refreshes the root Argo CD app target revision

Verification:

```bash
kubectl -n ml-team-a get wf "$WF" -o json | jq -r '.spec.arguments.parameters[] | select(.name=="git_default_branch")'
```

## Hub dispatcher fails with `workflowtaskresults ... forbidden`

Symptom:

- `mlflow-tag-sync-hub` pod `wait` logs contain:
  - `cannot create resource "workflowtaskresults"...`
  - `cannot patch resource "workflowtaskresults"...`

Cause:

- `argo/mlflow-tag-sync-dispatcher` service account missing Argo executor task-result permissions.

Fix in this repo:

- `infra/argo-workflows/cron/rbac-mlflow-tag-sync-dispatcher.yaml`
  - grants `workflowtaskresults` verbs:
    - `create`, `get`, `list`, `watch`, `patch`, `update`

Verification:

```bash
kubectl get clusterrole mlflow-tag-sync-dispatcher -o yaml | rg -n "workflowtaskresults|verbs"
```

## KServe revisions churn every 5-minute poll (no real model change)

Symptom:

- Git diff on every sync run only changes `platform.ai-ml/trace-id`.
- KServe/Knative repeatedly rolls new revisions even when alias/intent is unchanged.

Cause:

- runtime trace IDs were being persisted into GitOps-managed manifest metadata.

Fix in this repo:

- `infra/argo-workflows/scripts/render_inferenceservice.py`
  - no longer writes `platform.ai-ml/trace-id` into rendered manifest.
- trace ID still exists in MLflow status tags (`gitops.sync.trace_id`) for auditability.

Expected behavior now:

- first run after this change may create one cleanup commit (removing prior trace-id annotation)
- subsequent unchanged sync cycles should be `noop/no_diff` and avoid revision churn

## Finalize succeeded but UI still shows old sync tags

Symptom:

- `finalize-status` pod logs show updated tags, but MLflow UI still displays old values.

Cause:

- UI caching/refresh lag.

Validation source of truth:

```bash
python3 - <<'PY'
from mlflow import MlflowClient
c = MlflowClient(tracking_uri="http://mlflow.ml-team-a.local")
for model in ["prod.ml-team-a.sklearn-iris", "prod.ml-team-a.xgboost-synth"]:
    try:
        mv = c.get_model_version_by_alias(model, "champion")
    except Exception as exc:
        print(model, "->", exc)
        continue
    print("\nmodel:", model, "version:", mv.version)
    for k in ["gitops.sync.status","gitops.sync.reason","gitops.sync.commit","gitops.sync.url","gitops.sync.trace_id","gitops.sync.updated_at"]:
        print(" ", k, "=", mv.tags.get(k))
PY
```

Then hard-refresh the MLflow UI tab.

## KServe predictor rejected by tenant quota

Symptom:
- Knative revision admission fails with:
  - `exceeded quota: tenant-quota, requested: limits.cpu=3500m ...`

Cause:
- Effective pod limits include queue-proxy and Istio sidecar, not only model container.

Current repo state:
- `teams/ml-team-a/resourcequota.yaml` defines a raised Team-a profile but is currently commented out in `teams/ml-team-a/kustomization.yaml`.

Checks:
- `MODEL_NAME="${MODEL_NAME:-xgboost-synth-v1}"`
- `kubectl -n ml-team-a describe inferenceservice "${MODEL_NAME}"`
- if quota profile is enabled, also check:
  - `kubectl -n ml-team-a describe resourcequota tenant-quota`

## KServe storage initializer hangs in `Running`

Symptom:
- `storage-initializer` does not complete while fetching model artifacts.

Cause:
- restrictive tenant egress policy blocks artifact access to MinIO.

Current repo state:
- shared tenant guardrails keep DNS and `istiod` control-plane egress at the
  namespace baseline, while `serving-runtime-egress-minio` carries the model
  artifact path explicitly

Check:
- `kubectl -n ml-team-a logs <predictor-pod> -c storage-initializer`

## KServe predictor intermittent queue-proxy readiness timeouts

Symptom:

- Pod event shows:
  - `Readiness probe failed: Get "http://<pod-ip>:15020/app-health/queue-proxy/readyz": context deadline exceeded`
- `istio-proxy` logs show probe forwarding failure to:
  - `http://<pod-ip>:8012/`

Meaning:

- This is Knative queue-proxy readiness timing during startup, not a workflow failure.
- Short transient failures can happen while model server is still warming up.

Platform mitigation in this repo:

- `infra/knative/manifests/serving-core/config-deployment-patch.yaml`
  - raises queue-proxy baseline resources:
    - `queue-sidecar-cpu-request`
    - `queue-sidecar-memory-request`
    - `queue-sidecar-cpu-limit`
    - `queue-sidecar-memory-limit`
- `infra/kserve/runtime-overrides/kserve-mlserver-runtime.yaml`
  - sets explicit model-container probes for `kserve-mlserver-custom`:
    - `readinessProbe.path: /v2/health/ready`
    - `startupProbe.path: /v2/health/live`
    - `readinessProbe.timeoutSeconds: 5`
    - `startupProbe.timeoutSeconds: 5`
  - this gives queue-proxy more time during warm-up and reduces transient
    startup probe failures on new revisions.

Verification:

```bash
kubectl -n knative-serving get cm config-deployment -o yaml | rg -n "queue-sidecar-(cpu|memory)-(request|limit)"
kubectl get clusterservingruntime kserve-mlserver-custom -o yaml | rg -n "readinessProbe|startupProbe|timeoutSeconds"
```

## Inference ingress returns `404` from `istio-envoy`

Symptom:
- `curl` to ingress with `Host` header returns `404` and empty body.

Typical cause:
- Knative URL is still `.svc.cluster.local` (cluster-local host does not match external ingress routing).

Current repo state:
- `infra/knative/manifests/serving-core/config-domain-patch.yaml` sets `ai-ml.local`.

Checks:
- `kubectl -n knative-serving get cm config-domain -o yaml | rg ai-ml.local`
- `MODEL_NAME="${MODEL_NAME:-xgboost-synth-v1}"`
- `kubectl -n ml-team-a get ksvc "${MODEL_NAME}-predictor" -o jsonpath='{.status.url}{"\n"}'`
- `kubectl -n ml-team-a get inferenceservice "${MODEL_NAME}" -o jsonpath='{.status.url}{"\n"}'`

If URL still ends with `.svc.cluster.local`:
- sync `knative-serving-core`
- recreate predictor KService:
  - `kubectl -n ml-team-a delete ksvc "${MODEL_NAME}-predictor"`

## Inference test payload/CLI gotchas

Symptoms:
- `Bad Request` when using wrong endpoint.
- `jq` parse error when piping `curl -i` output.

Fixes:
- Use endpoint `/v2/models/<model-name>/infer` (model name must match runtime config).
- For `jq`, use `curl -s` (no headers):
  - `curl -s ... | jq .`

## Accessing team-a MLflow

1. Ensure ingress gateway service exists and has IP:
   - `kubectl -n istio-system get svc istio-ingressgateway -o wide`
2. Resolve host from Team-a VirtualService (do not hardcode):
   - `MLFLOW_HOST="$(kubectl -n ml-team-a get virtualservice mlflow -o jsonpath='{.spec.hosts[0]}')"`
3. Test through ingress:
   - `curl -i "http://<INGRESS_IP>/health" -H "Host: ${MLFLOW_HOST}"`
4. Optional hosts file convenience:
   - `<INGRESS_IP> <MLFLOW_HOST>`
5. Team-a MLflow reference doc:
   - `teams/ml-team-a/mlflow/README.md`

## Laptop profile (single tenant)

- Keep only `ml-team-a-root` active on constrained laptops.
- Leave `ml-team-b-root` manifest committed for opt-in demos later.
