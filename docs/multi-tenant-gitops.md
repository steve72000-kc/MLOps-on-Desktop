# Multi-Tenant GitOps Model

## Goals

- Shared platform stack managed once (`infra/`).
- Team isolation through separate team root Argo CD applications.
- One MLflow instance per team, with shared base defaults and team overlays.
- Team-owned model serving manifests per namespace through KServe + Knative.
- Team-facing workflow centered on MLflow and git writeback automation.

## Ownership Model

Shared ownership:

- `clusters/kind/bootstrap/` -> points to `infra/` only.
- `infra/` -> shared platform components and team root app definitions.
- `infra/argocd/` -> per-team root Argo CD applications.
- `infra/argo-workflows/` -> Argo Workflows controller install + shared workflow template.
- `infra/monitoring/` -> shared platform observability (metrics, alerts, dashboards, logs).
- `infra/mlflow/base/` -> base MLflow Helm values used by all teams.
- `infra/mlflow/pv-ml-team-*.yaml` -> static hostPath PVs for per-team sqlite persistence.
- `infra/argocd/kustomization.yaml` -> activation toggle for team root apps in laptop mode.
- `infra/knative/manifests/serving-core/config-domain-patch.yaml` -> mesh-routable Knative domain (`ai-ml.local`).

Team ownership:

- `teams/<team>/` -> all team-scoped runtime config.
- `teams/<team>/mlflow/` -> team MLflow app + values + routing/config.
- `teams/<team>/models/` -> team deployment Argo CD child app definitions.
- `teams/<team>/workflows/` -> tenant runtime prerequisites (RBAC/secrets/configmap).
- `teams/_bases/tenant-core/` + `teams/<team>/core/` -> shared tenant guardrails and team-specific policy patches.
- `teams/<team>/resourcequota.yaml` -> optional tenant quota profile for admission/resource shaping.

Tenant app ownership (promotion targets):

- `apps/tenants/<team>/...`

## Reconciliation Chain

1. `ai-ml-root` syncs `clusters/kind/bootstrap`.
2. Bootstrap syncs `infra/`.
3. `infra/argocd` creates team root apps.
4. Team root app syncs `teams/<team>/`.
5. Team MLflow app under `teams/<team>/mlflow/application.yaml` deploys MLflow chart with:
   - shared values from `infra/mlflow/base/values.yaml`
   - team values from `teams/<team>/mlflow/values.yaml`
6. Team deployment app under `teams/<team>/models/application-*.yaml` reconciles `apps/tenants/<team>/...` manifests.
7. Shared hub workflow (`infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`) dispatches per-tenant prune + sync workflows.
8. Shared monitoring app (`infra/monitoring/application.yaml`) scrapes platform/team namespaces and centralizes logs.

## Team-A Serving Baseline

- InferenceService GitOps path: `apps/tenants/ml-team-a/deployments/`
- Dynamic writeback target: `<intent-name>.yaml`
- Runtime path:
  1. Request to `istio-ingressgateway` (`172.29.0.203`)
  2. `Host` header set to KServe/Knative URL host
  3. Runtime endpoint: `/v2/health/ready` (or `/v2/models/<model-name>/infer`)

Observed/implemented guardrails:

- Team-a high-capacity quota profile exists (`teams/ml-team-a/resourcequota.yaml`) but is currently commented out in `teams/ml-team-a/kustomization.yaml`.
- Team network policies allow `istio-system` and `knative-serving` traffic.
- Team network policies allow MinIO artifact access on TCP `9000`, Gitea writeback on TCP `3000`, and DNS to `kube-dns`.

## Current Activation Profile

- Default local profile enables only `ml-team-a-root`.
- `ml-team-b-root` remains committed but commented out in `infra/argocd/kustomization.yaml`.
- Re-enable team-b by uncommenting `application-ml-team-b-root.yaml` in `infra/argocd/kustomization.yaml`.

## MLflow Pattern

Shared defaults in infra:

- sqlite backend
- proxied artifacts
- server env defaults (`MLFLOW_SERVER_ALLOWED_HOSTS`, `MLFLOW_SERVER_X_FRAME_OPTIONS`)
- Istio sidecar injection

Team-specific overlays:

- PVC claim (`mlflow-data`) bound to team PV for sqlite file persistence
- tenant-scoped MinIO credentials secret (`mlflow-s3-credentials`)
- S3 artifact root partition:
  - team-a -> `s3://mlflow-ml-team-a/artifacts`
  - team-b -> `s3://mlflow-ml-team-b/artifacts`
- per-team VirtualService host and metadata config

MinIO tenant partitioning model:

- bootstrap job in `infra/minio/manifests/tenant-bootstrap-job.yaml` creates:
  - buckets `mlflow-ml-team-a` and `mlflow-ml-team-b`
  - users `MLFLOWTEAMA` and `MLFLOWTEAMB`
  - bucket-scoped RW policies per team

## Promotion Flow (Implemented)

1. Team updates model alias in MLflow (current default hub profile polls `champion`).
2. Central hub `CronWorkflow` in `argo` namespace runs every 5 minutes and discovers active models by alias + intent tags.
3. Hub dispatches one tenant prune workflow (`ClusterWorkflowTemplate/mlflow-tag-prune`) each poll.
4. Hub dispatches one tenant sync workflow (`ClusterWorkflowTemplate/mlflow-tag-sync`) per discovered model.
5. If discovery output is `[]`, sync dispatch is skipped and prune-only is expected.
6. Sync workflow resolves concrete model version by alias and resolves intent JSON from model version tags.
7. Sync workflow injects platform-owned fields, runs server-side dry-run validation, and applies optional policy command.
8. Sync workflow writes manifest to `apps/tenants/<team>/...`, commits on diff only, and pushes.
9. Prune workflow removes stale workflow-managed manifests and updates kustomization entries.
10. Tenant deployment Argo CD app (`ml-team-a-deployments`, `ml-team-b-deployments`) reconciles cluster state.
11. Sync workflow writes status tags back to MLflow model version (`accepted`, `rendered`, `applied`, `failed`).

Stability behavior:
- `trace_id` is still written to MLflow status tags (`gitops.sync.trace_id`) for run correlation.
- `trace_id` is intentionally not persisted into rendered `InferenceService` manifest annotations.
- This prevents no-op poll cycles from generating unnecessary Git diffs and KServe/Knative revisions.

Detailed design:
- `docs/mlflow-intent-writeback-plan.md`

## Local Laptop Profile

- Keep one team root app active by default to reduce memory pressure.
- Keep additional team definitions committed for opt-in multi-tenant demos.
- MetalLB pool is fixed (`172.29.0.200-172.29.0.220`).
