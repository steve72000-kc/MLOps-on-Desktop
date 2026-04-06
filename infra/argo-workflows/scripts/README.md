# MLflow Tag Sync Scripts

These scripts implement the alias-driven MLflow -> GitOps flow used by:

- `ClusterWorkflowTemplate/mlflow-tag-sync`
- `ClusterWorkflowTemplate/mlflow-tag-prune`

Script execution order in a successful champion sync:
1. `resolve_alias_and_intent.py`
2. `update_mlflow_status.py` (`accepted`)
3. `render_inferenceservice.py`
4. `update_mlflow_status.py` (`rendered`)
5. `git_writeback.sh`
6. `update_mlflow_status.py` (`applied` or `failed`, plus optional commit and URL)

These scripts are mounted into workflow pods through tenant namespace ConfigMaps named `mlflow-tag-sync-scripts`, generated under:

- `teams/_bases/workflows/kustomization.yaml`
- included by each tenant overlay through `teams/<tenant>/workflows/`

## Script Contracts

### `resolve_alias_and_intent.py`
Purpose:
- Resolve `(registered_model, alias)` to concrete model version.
- Load deployment intent from MLflow tags (`inline` or `artifact-ref`).
- Validate minimal JSON shape.

Inputs:
- args: `--registered-model`, `--alias`, `--trace-id`, `--output-dir`
- env/arg: `MLFLOW_TRACKING_URI`
- optional args/env:
  - `--network-timeout-seconds` / `MLFLOW_SYNC_NETWORK_TIMEOUT_SECONDS`
  - `--preflight-retries` / `MLFLOW_SYNC_PREFLIGHT_RETRIES`

MLflow tags read:
- `kserve.intent.mode`
- `kserve.intent.payload`
- `kserve.intent.ref`

Outputs (`/tmp/outputs/*`):
- `sync_status`, `reason`, `trace_id`, `model_version`, `run_id`, `source`, `intent_hash`, `intent_json_b64`, `intent_name`

Common reasons:
- `accepted`
- `mlflow_unreachable`
- `alias_lookup_failed`
- `intent_missing`
- `invalid_json`

### `render_inferenceservice.py`
Purpose:
- Render a tenant-safe `InferenceService` from the resolved intent payload.
- Enforce platform-owned fields and stable metadata used for idempotent writeback.
- Keep runtime trace IDs out of Git-managed manifest metadata (trace is tracked via MLflow status tags instead).
- Backward-compat map legacy runtime `kserve-mlserver` to `kserve-mlserver-custom`.

Inputs:
- args: `--tenant`, `--namespace`, `--registered-model`, `--alias`, `--resolved-version`, `--intent-hash`, `--trace-id`, `--intent-json-b64`, `--storage-secret-name`, `--output-dir`

Outputs:
- `render_status`, `reason`, `manifest_b64`, `metadata_name`

Common reasons:
- `rendered`
- `invalid_json`

### `update_mlflow_status.py`
Purpose:
- Write workflow status tags back to a specific MLflow model version.

Inputs:
- args: `--registered-model`, `--model-version`, `--sync-status`, `--reason`, `--trace-id`
- optional args:
  - `--commit-sha`
  - `--deployment-url`
  - `--network-timeout-seconds`
  - `--tag-write-retries`
- env/arg: `MLFLOW_TRACKING_URI`

Tags written:
- `gitops.sync.status`
- `gitops.sync.reason`
- `gitops.sync.trace_id`
- `gitops.sync.updated_at`
- optional: `gitops.sync.commit`, `gitops.sync.url`

Status progression guard:
- Non-failure states are monotonic: `accepted -> rendered -> applied`.
- Downgrade attempts are ignored (for example `applied` will not be overwritten by `rendered`).
- `failed` is always allowed so new failures are visible.

### `git_writeback.sh`
Purpose:
- Clone GitOps repo, write rendered manifest to tenant path, commit if diff, and push.

Inputs:
- args:
  - `--tenant`, `--registered-model`, `--alias`, `--trace-id`
  - `--resolved-version`, `--intent-hash`, `--intent-name`, `--manifest-b64`
  - `--default-branch`, `--challenger-mode`, `--output-dir`
- env:
  - `GIT_REPO_URL`
  - `GIT_USERNAME`, `GIT_PASSWORD` (for HTTP auth)
  - `GIT_DEFAULT_BRANCH` (fallback default is `auto`, which resolves remote `HEAD`)
  - `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`

Reads tenant routing from:
- `teams/<tenant>/tenant-config.yaml` in cloned repo

Writeback path behavior:
- `writebackRoot` is authoritative and points at `apps/tenants/<team>`
- manifests are written under `deployments/<intent-name>.yaml`
- challenger preview uses `deployments/challenger-<intent-name>.yaml`
- if `--intent-name` is empty, the script falls back to
  `deployments/inferenceservice.yaml` or
  `deployments/challenger-inferenceservice.yaml`

Outputs:
- `writeback_status`, `reason`, `commit_sha`, `manifest_path`

Statuses:
- `applied`
- `noop` (`no_diff`, `challenger_status_only`)
- `failed`

Failure reasons:
- `git_repo_missing`
- `git_auth_failed`
- `git_host_unreachable`
- `git_unknown_error` (includes unknown clone errors such as missing branch)
- `tenant_config_missing`
- `render_invalid`
- `git_commit_failed`
- `git_push_conflict`
- `git_push_failed`

### `git_prune_manifests.sh`
Purpose:
- Remove stale managed manifests from tenant GitOps deployment paths when
  models are no longer discovered for a polled alias (for example no
  `champion` alias in MLflow).

Inputs:
- args:
  - `--tenant`, `--alias`, `--active-models-json`, `--output-dir`
  - optional: `--default-branch`, `--repo-url`
- env:
  - `GIT_REPO_URL`
  - `GIT_USERNAME`, `GIT_PASSWORD` (for HTTP auth)
  - `GIT_DEFAULT_BRANCH` (fallback default is `auto`, which resolves remote `HEAD`)
  - `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`

Behavior:
- reads tenant routing from `teams/<tenant>/tenant-config.yaml`
- scans tenant deployment manifests and prunes files managed by the sync flow
  (identified by `platform.ai-ml/registered-model`) when model is not in
  `--active-models-json`
- updates local `kustomization.yaml` entries for removed manifest files
- retries git clone with short backoff before returning final failure

Outputs:
- `prune_status`, `reason`, `commit_sha`, `pruned_paths_json`

Statuses:
- `applied`
- `noop` (`no_stale_manifests`)
- `failed`

Failure reasons:
- `git_repo_missing`
- `git_auth_failed`
- `git_host_unreachable`
- `git_unknown_error`
- `tenant_config_missing`
- `git_commit_failed`
- `git_push_conflict`
- `git_push_failed`

## Operational Notes

- Branch mismatch is a common failure mode. The checked-in repo uses `auto`,
  which resolves the remote default branch from Gitea `HEAD`. If you pin an
  explicit branch instead, keep `tenant-config`, child workflow args, and
  `GIT_DEFAULT_BRANCH` in the tenant Git secret aligned.
- If `writeback` fails, check `writeback-manifest` pod `main` logs first; clone/push stderr is printed.
- If `prune` fails, check `prune-stale-manifests` pod `main` logs first; clone/push stderr is printed and workflow now exits non-zero on `prune_status=failed`.
- Scripts are centrally owned here; no team-local script copies are required.
