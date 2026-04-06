# Alias-Driven MLflow Intent To GitOps YAML Architecture

This document reflects the implemented behavior in this repo.

## Purpose

ML teams set deployment intent on MLflow model versions, and platform automation:

1. resolves alias -> concrete model version,
2. renders tenant-scoped KServe manifest,
3. validates,
4. commits/pushes to GitOps repo,
5. writes sync outcome tags back to MLflow.

Primary ownership model:

- MLflow registry is source of model selection and deployment intent.
- Git repo is source of desired deployment state.
- Argo CD remains deployment reconciler.

## Implemented Components

- Shared workflow template:
  - `infra/argo-workflows/templates/mlflow-tag-sync-workflow.yaml`
  - `ClusterWorkflowTemplate/mlflow-tag-sync`
- Shared scripts:
  - `infra/argo-workflows/scripts/resolve_alias_and_intent.py`
  - `infra/argo-workflows/scripts/render_inferenceservice.py`
  - `infra/argo-workflows/scripts/update_mlflow_status.py`
  - `infra/argo-workflows/scripts/git_writeback.sh`
- Primary dispatcher:
  - `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`
- Team wiring:
  - `teams/<team>/workflows/*`
  - script ConfigMap generated from `teams/_bases/workflows/` using the shared files in `infra/argo-workflows/scripts/*`

## Runtime Contract

Workflow args (effective):

- `tenant`
- `namespace`
- `registered_model`
- `alias`
- `trace_id`
- `challenger_mode`
- `scripts_configmap`
- `mlflow_secret_name`
- `git_secret_name`
- `git_default_branch`
- `dry_run_enabled`
- `policy_command`
- `url_scheme`
- `public_domain`

Current default branch mode in the workflow path is `auto`, which resolves the
remote repo's default branch from Gitea `HEAD`.

## MLflow Intent Contract

Model version tags read by resolve step:

- `kserve.intent.mode=inline|artifact-ref`
- `kserve.intent.payload=<json-string>` (inline)
- `kserve.intent.ref=artifacts:/deploy-intent.json` (artifact-ref)

Intent minimal requirements:

- `metadata.name`
- `spec`

Platform-owned fields are enforced during render:

- `apiVersion: serving.kserve.io/v1beta1`
- `kind: InferenceService`
- `metadata.namespace=<tenant namespace>`
- traceability labels/annotations (`platform.ai-ml/*`)

## Workflow Step Semantics (Implemented)

1. `resolve-alias-and-intent`
   - Resolves alias with `MlflowClient.get_model_version_by_alias`.
   - Loads and validates intent.
   - Emits `sync_status`, `reason`, `model_version`, `intent_hash`, etc.
2. `check-idempotency`
   - Currently emits `changed=true` with reason `evaluated_no_cache`.
   - Cluster state cache writes are intentionally bypassed.
3. `decide-deploy`
   - `challenger + status-only` => no deployment writeback.
4. `status-accepted`
   - Writes MLflow sync tags with status `accepted`.
5. `render-manifest`
   - Produces rendered manifest payload.
6. `status-rendered`
   - Writes MLflow sync tags with status `rendered`.
7. `validate-manifest`
   - Performs validation; with dry-run enabled:
     - runs `kubectl apply --dry-run=server` only if `kubectl` exists in container.
     - otherwise marks `validated_no_dry_run` and continues.
8. `writeback-manifest`
   - Clones repo, writes tenant path, commits on diff, pushes branch.
9. `persist-idempotency-state`
   - Currently disabled; returns `state_store_disabled`.
10. `finalize-status`
   - Computes final outcome and writes final MLflow tags.

## Final Status Behavior

MLflow tags written:

- `gitops.sync.status`
- `gitops.sync.reason`
- `gitops.sync.trace_id`
- `gitops.sync.updated_at`
- optional: `gitops.sync.commit`, `gitops.sync.url`

Final status is determined in `finalize`:

- `writeback_status=applied|noop` => final `applied`
- `writeback_status=failed` => final `failed`

`update_mlflow_status.py` enforces monotonic non-failure status progression:

- `accepted -> rendered -> applied`
- downgrades are skipped
- `failed` is always allowed

## Current Branching Reality

The live writeback path now defaults to `auto` and follows the repo's current
default branch. `bootstrap/gitops-init.sh` now reconciles that remote default
branch to the branch it pushes during install.

Required alignment points:

- `infra/argo-workflows/templates/mlflow-tag-sync-workflow.yaml`
- `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`
- `teams/<team>/tenant-config.yaml`
- `teams/<team>/workflows/secret-mlflow-sync-git-credentials.yaml`
- `infra/argo-workflows/scripts/git_writeback.sh` fallback
- `infra/argo-workflows/scripts/git_prune_manifests.sh` fallback

If you pin an explicit branch instead of `auto`, keep every source aligned to
that same branch. Drift can surface as clone/push failures (often
`git_unknown_error`).

## Failure Codes Seen In Practice

Resolve/intent:

- `mlflow_unreachable`
- `alias_lookup_failed`
- `intent_missing`
- `invalid_json`

Validate:

- `dry_run_failed`
- `policy_denied`
- `validated_no_dry_run` (dry-run fallback path)

Writeback:

- `git_repo_missing`
- `git_auth_failed`
- `git_host_unreachable`
- `git_unknown_error`
- `git_commit_failed`
- `git_push_conflict`
- `git_push_failed`

## Operational Notes

- A workflow showing `Running` is not necessarily hung; often only later nodes are still initializing.
- `PodInitializing` on `main`/`wait` is normal during startup.
- Prefer querying pods dynamically by workflow label; avoid stale hardcoded pod names.
- MLflow UI can lag/cache tags. Use API/CLI as source of truth when validating final status.

## Scope Boundaries

- polling-based sync via the central CronWorkflow hub
- alias-driven champion/challenger handling
- GitOps writeback and MLflow status feedback

## Related References

- Shared workflow runbook:
  - `infra/argo-workflows/README.md`
- Script contracts:
  - `infra/argo-workflows/scripts/README.md`
- Team workflow docs:
  - `teams/ml-team-a/workflows/README.md`
  - `teams/ml-team-b/workflows/README.md`
- Troubleshooting:
  - `docs/troubleshooting.md`
