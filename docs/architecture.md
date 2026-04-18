# Architecture

This repo models a local-first, multi-tenant ML platform where MLflow carries
deployment intent, Argo Workflows validates and writes Git-managed manifests,
Argo CD reconciles them, and KServe serves models behind Knative and Istio.
The default laptop profile keeps one tenant enabled, but the repo structure
preserves platform, team, and tenant boundaries.

## System Flow

1. A team registers or updates a model version in its own MLflow instance and
   assigns a deployment alias.
2. The central hub `CronWorkflow/mlflow-tag-sync-hub` in `argo` runs every 5
   minutes, discovers labeled tenant configs, and dispatches one sync workflow
   per discovered model plus one prune workflow per tenant poll.
3. `ClusterWorkflowTemplate/mlflow-tag-sync` resolves alias + intent, renders a
   tenant-safe `InferenceService`, validates it, and writes it to
   `apps/tenants/<team>/deployments/<intent-name>.yaml`.
4. The team deployment Argo CD app reconciles that Git state.
5. KServe, Knative, and Istio expose the model through the ingress path.
6. Prometheus, Grafana, Loki, and workflow status provide the debugging
   surface.

Rendered manifests intentionally omit `platform.ai-ml/trace-id`, so repeated
polls converge to `noop/no_diff` when intent is unchanged.

## Bootstrap Flow

1. Kind cluster creation (ephemeral local cluster).
   - bootstrap applies best-effort Kind node runtime tuning for `nofile` and `inotify` limits (configurable via env vars).
2. MetalLB installation + IP pool in Docker `kind` network.
3. Argo CD installation (`argocd-server` exposed as `LoadBalancer`).
4. Gitea installation (`gitea-http` and `gitea-ssh` exposed as `LoadBalancer`) backed by a static hostPath PV/PVC for sqlite and repo storage.
5. Mandatory GitOps init (`bootstrap/gitops-init.sh`):
   - local git `gitea` remote reconciliation while preserving any existing `origin` remote
   - repo creation/push to Gitea
   - current local branch is set to track `gitea/<branch>`
   - current bootstrap branch is reconciled as the in-cluster repo default branch
   - Argo CD `Application` creation/update for `ai-ml-root`
6. Argo CD syncs infra child apps including MinIO (`infra/minio`) and monitoring (`infra/monitoring`).

## Fixed Endpoints

- MetalLB pool: `172.29.0.200-172.29.0.220`
- Argo CD LB IP: `172.29.0.200`
- Gitea HTTP LB IP: `172.29.0.201`
- Gitea SSH LB IP: `172.29.0.202`
- Istio ingress gateway target IP: `172.29.0.203` (when ingress gateway app is enabled/synced)
- MinIO LB IP: `172.29.0.204`
- Grafana LB IP: `172.29.0.205`

## GitOps Layering And Ownership

- `ai-ml-root` tracks `clusters/kind/bootstrap`.
- `clusters/kind/bootstrap` composes only `infra/`.
- `infra/kustomization.yaml` composes:
  - platform apps (`argo-workflows`, `cert-manager`, `istio`, `knative`, `kserve`, `mlflow`, `minio`, `monitoring`)
  - `infra/argocd/` team root applications.
- `infra/argocd/` creates:
  - `ml-team-a-root` -> `teams/ml-team-a`
  - `ml-team-b-root` -> `teams/ml-team-b`
- `infra/argocd/kustomization.yaml` enables team-a and leaves team-b commented
  out by default for the laptop profile.
- Each team root app owns everything under its `teams/<team>/` path.

## Platform Components

- `cert-manager` (Helm): `charts.jetstack.io/cert-manager`, `v1.19.1`, CRDs enabled.
- `istio` (Helm): `base` and `istiod` `1.24.2`, demo-sized control plane (`istiod` replicas `1`).
- `istio ingress gateway` (Helm): `gateway` `1.24.2`, `LoadBalancer` target IP `172.29.0.203`, with Helm params + `skipSchemaValidation` due chart schema edge cases.
- `knative-serving` (official YAML):
  - `serving-crds.yaml` `knative-v1.20.3`
  - `serving-core.yaml` `knative-v1.20.3`
  - `net-istio.yaml` `knative-v1.20.2`
  - `config-domain` patched by `infra/knative/manifests/serving-core/config-domain-patch.yaml`:
    - `ai-ml.local: ""`
- `kserve` (Helm OCI): `kserve-crd` + `kserve` `v0.16.0` in `kserve` namespace, with webhook diff ignores and sync retries.
- KServe runtime override (repo source):
  - `infra/kserve/runtime-overrides/kserve-mlserver-runtime.yaml`
  - runtime name: `kserve-mlserver-custom`
  - readiness probe path `/v2/health/ready`, startup probe path `/v2/health/live`
  - probe timeout hardening (`timeoutSeconds: 5`)
- `argo-workflows` (manifests):
  - upstream install manifest `v3.7.3`
  - `CronWorkflow/mlflow-tag-sync-hub`
  - `ClusterWorkflowTemplate/mlflow-tag-sync`
  - `ClusterWorkflowTemplate/mlflow-tag-prune`
  - dispatcher service account and RBAC for child workflow submission
- `gitea` (Helm): sqlite backend persisted by a static hostPath PV/PVC mounted at `/data`.
- `mlflow` (Helm): community chart `1.7.3`, one app per team.
- `minio` (manifests): single replica in `minio` namespace backed by static hostPath PV/PVC.
- `mlflow` storage PVs (manifests): static hostPath PVs for `ml-team-a` and `ml-team-b`.
- `monitoring` (Argo multi-source app):
  - `kube-prometheus-stack` chart `67.10.0`
  - `loki` chart `6.27.0`
  - `promtail` chart `6.17.0`
  - repo-managed dashboards/alerts/scrape resources under `infra/monitoring/manifests/`
  - Grafana exposed by static LB (`172.29.0.205`) and host route (`grafana.platform.local`)
  - laptop profile defaults:
    - `prometheus-node-exporter` disabled
    - Loki canary/tests/caches/rules sidecar disabled
    - Promtail runs as DaemonSet with namespace + node-local relabel filtering

## Team Layout

Each team path contains:

- `teams/<team>/mlflow/`
- `teams/<team>/models/` (deployment app definitions)
- `teams/<team>/workflows/` (tenant runtime wiring: SA/RBAC/secrets/configmap)
- shared workflow logic/scripts are centrally owned under `infra/argo-workflows/scripts/`
- `apps/tenants/<team>/...` (rendered deployment manifests)

Common team resources include:

- `Namespace` (+ `istio-injection: enabled`)
- `ResourceQuota`
- `LimitRange`
- `NetworkPolicy`
- `tenant-config.yaml`

`tenant-config.yaml` is the tenant descriptor used by the hub discovery path.
The checked-in tenant configs define:

- `trackingUri`
- `syncAlias`
- `challengerMode`
- `writebackRoot`
- `gitDefaultBranch`
- `scriptsConfigMapName`
- `mlflowSecretName`
- `gitSecretName`

Team network policies keep only DNS plus `istio-system/app=istiod` at the
namespace baseline. Tenant access to MLflow, Gitea, MinIO, and serving
runtimes is role-scoped, and mesh ingress trust is narrowed to the pods that
actually source traffic:

- hub pods in `argo` carry `platform.ai-ml/network-role=hub-dispatcher` and
  are limited to Kubernetes API, tenant MLflow, DNS, and
  `istio-system/app=istiod`
- tenant workflow pods carry `platform.ai-ml/network-role=workflow` and are
  limited to MLflow, Gitea, Kubernetes API, DNS, MinIO, and `istiod`
  control-plane egress
- tenant MLflow pods allow ingress only from hub pods, tenant workflow pods,
  and `istio-system` ingress gateway pods; egress to MinIO remains explicit
- rendered KServe predictor pods carry
  `platform.ai-ml/network-role=serving-runtime` and allow ingress only from the
  `istio-system` ingress gateway and `knative-serving/app=activator` path plus
  egress to MinIO, DNS, and `istiod`

`teams/_bases/workflows/` provides the shared tenant workflow runtime:

- `ServiceAccount/mlflow-tag-sync`
- tenant `Role` and `RoleBinding`
- tenant-local `ConfigMap/mlflow-tag-sync-scripts` generated from
  `infra/argo-workflows/scripts/*`
- workflow egress policies for Kubernetes API, MLflow, Gitea, and MinIO

`teams/_bases/tenant-core/networkpolicy-mlflow-allow-argo.yaml` allows hub
pods in namespace `argo` to reach tenant MLflow pods for model discovery.

`infra/argo-workflows/networkpolicy-hub-egress.yaml` keeps the central hub in
`argo` least-privileged as well; unrelated pods in the namespace do not inherit
tenant MLflow access.

The checked-in team-a baseline lives under
`apps/tenants/ml-team-a/deployments/`:

- primary dynamic writeback path: `<intent-name>.yaml`
- stale model manifests are removed by `mlflow-tag-prune` when no longer discovered
- automation trigger path:
  - `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`
  - hub discovers tenants from labeled `tenant-config` `ConfigMap`s
  - dispatches one per-model sync workflow and one per-poll prune workflow
  - if model discovery returns `[]`, sync dispatch is skipped and prune-only
    execution is expected
- Team-a quota profile file for higher admission overhead remains available at `teams/ml-team-a/resourcequota.yaml`:
  - `requests.cpu: 12`
  - `limits.cpu: 18`
  - currently disabled in `teams/ml-team-a/kustomization.yaml` for local testing
- Platform runtime hardening for all teams:
  - `infra/kserve/runtime-overrides/kserve-mlserver-runtime.yaml`
  - applies explicit `readinessProbe`/`startupProbe` timeouts on
    `ClusterServingRuntime/kserve-mlserver-custom`.

## MLflow Layout

- Shared base values: `infra/mlflow/base/values.yaml`
  - sqlite backend
  - proxied artifact serving
  - required env vars (`MLFLOW_SERVER_ALLOWED_HOSTS`, `MLFLOW_SERVER_X_FRAME_OPTIONS`)
  - Istio sidecar injection
- Team overrides: `teams/<team>/mlflow/values.yaml`
  - PVC mount (`mlflow-data`) for `/mlflow/data` sqlite persistence
  - MinIO S3 artifact store (`artifactRoot.s3`) with team-scoped existing secret
  - dedicated MLflow service account (`mlflow-runtime`)
- Team MLflow PVCs:
  - `teams/ml-team-a/mlflow/pvc.yaml` -> `mlflow-ml-team-a-pv`
  - `teams/ml-team-b/mlflow/pvc.yaml` -> `mlflow-ml-team-b-pv`
- Team artifact partitions:
  - `s3://mlflow-ml-team-a/artifacts`
  - `s3://mlflow-ml-team-b/artifacts`
- Team MLflow app and routing:
  - `teams/<team>/mlflow/application.yaml`
  - `teams/<team>/mlflow/virtualservice-mlflow.yaml`

## Storage And Persistence

- `bootstrap/install.sh` mounts host `${ROOT_DIR}/.local/gitea-data` into every
  Kind node at `/var/local/gitea-data`.
- `bootstrap/install.sh` mounts host `${ROOT_DIR}/.local/minio-data` into every
  Kind node at `/var/local/minio-data`.
- Gitea PV points to `/var/local/gitea-data/gitea`.
- MinIO PV points to `/var/local/minio-data/minio`.
- Deleting the Kind cluster alone removes Kubernetes objects but not host object data.
- `bootstrap/install.sh` wipes local Gitea data before reinstalling the cluster.
- `bootstrap/uninstall.sh` also wipes local Gitea data.
- Intentional data wipe uses `./bootstrap/reset-minio-data.sh --force`; if elevated cleanup is needed, invoking it through `sudo` restores ownership to the calling user.
- Gitea sqlite and Git repositories survive pod restarts and container replacement while the cluster is running.
- MLflow sqlite is persisted via per-team PVCs bound to static hostPath PVs.
- MinIO bootstraps tenant buckets, users, and policies for MLflow artifact
  partitioning.

## Laptop Profile

- Keep one team root app enabled when resources are constrained.
- Leave additional team root apps committed but disabled for demos or local
  expansion.

## Mesh Routing Notes

- Expected host style after Knative domain patch:
  - `<model-name>-predictor.ml-team-a.ai-ml.local`
- If `KService`/`InferenceService` URL remains `.svc.cluster.local`, sync `knative-serving-core` and recreate the KService:
  - `kubectl -n ml-team-a delete ksvc <model-name>-predictor`
