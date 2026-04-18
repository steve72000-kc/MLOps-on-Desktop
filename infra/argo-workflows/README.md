# Argo Workflows Layer

`infra/argo-workflows/` installs the shared workflow controller and defines the
central hub, shared workflow templates, and centrally owned scripts used for
MLflow alias-driven GitOps writeback.

## Composition

`infra/argo-workflows/kustomization.yaml` renders:

- `namespace.yaml`
- upstream Argo Workflows install manifest `v3.7.3`
- `templates/mlflow-tag-sync-workflow.yaml`
- `templates/mlflow-tag-prune-workflow.yaml`
- `cron/rbac-mlflow-tag-sync-dispatcher.yaml`
- `cron/mlflow-tag-sync-hub-cron.yaml`
- `networkpolicy-hub-egress.yaml`

Shared workflow scripts live under `infra/argo-workflows/scripts/`. They are
not rendered directly here. Tenant workflow bases generate a tenant-local
`ConfigMap/mlflow-tag-sync-scripts` from those files.

## Hub CronWorkflow

`cron/mlflow-tag-sync-hub-cron.yaml` defines:

- `CronWorkflow/mlflow-tag-sync-hub`
- namespace `argo`
- hub pod label `platform.ai-ml/network-role=hub-dispatcher`
- schedule `*/5 * * * *`
- timezone `America/New_York`
- `concurrencyPolicy: Forbid`
- `startingDeadlineSeconds: 120`
- history limits `3` successful and `3` failed runs

Hub dispatch starts with `discover-tenants`, which queries the Kubernetes API
for `ConfigMap` objects labeled `platform.ai-ml/tenant-config=true`.

Tenant configs are skipped when `data.syncEnabled` is `false`, `0`, or `no`.

Required tenant config data:

- `tenant`
- `namespace`
- `trackingUri`

Tenant config defaults applied by the hub when keys are omitted:

- `syncAlias: champion`
- `challengerMode: status-only`
- `scriptsConfigMapName: mlflow-tag-sync-scripts`
- `mlflowSecretName: mlflow-s3-credentials`
- `gitSecretName: mlflow-sync-git-credentials`
- `gitDefaultBranch: auto`

For each discovered tenant, `discover-models` queries that tenant MLflow
registry and selects registered models where:

- the configured alias resolves to a model version
- `kserve.intent.mode` is present
- either `kserve.intent.payload` or `kserve.intent.ref` is present

Per tenant poll, the hub creates:

- one tenant `Workflow` with generateName `mlflow-tag-prune-`
- one tenant `Workflow` with generateName `mlflow-tag-sync-` per discovered
  model

If `discover-models` returns `[]`, the prune workflow still runs and no sync
workflows are created.

The hub submits child sync workflows with:

- `serviceAccountName: mlflow-tag-sync`
- `trace_id: {{workflow.uid}}-{{tenant}}-{{alias}}`
- `dry_run_enabled: "true"`
- `policy_command: ""`

The hub passes `git_default_branch` through from the tenant config. When the
tenant config omits it, the hub defaults to `auto` instead of a hardcoded branch
name.

`url_scheme` and `public_domain` are not set by the hub, so child sync
workflows use the template defaults `http` and `ai-ml.local` unless overridden
manually.

## Tenant Runtime Contract

Each tenant namespace that participates in the shared flow must contain:

- a labeled `tenant-config` `ConfigMap`
- `ServiceAccount/mlflow-tag-sync`
- tenant `Role` and `RoleBinding` for `mlflow-tag-sync`
- tenant-local `ConfigMap/mlflow-tag-sync-scripts`
- secret `mlflow-sync-git-credentials`
- secret `mlflow-s3-credentials`

`teams/_bases/workflows/` provides:

- `ServiceAccount/mlflow-tag-sync`
- tenant `Role` and `RoleBinding`
- `NetworkPolicy/workflow-kube-api-egress`
- `NetworkPolicy/workflow-egress-mlflow`
- `NetworkPolicy/workflow-egress-gitea`
- `NetworkPolicy/workflow-egress-minio`
- `ConfigMap/mlflow-tag-sync-scripts`

Tenant least-privilege networking is split across the shared workflow and
tenant-core bases:

- `infra/argo-workflows/networkpolicy-hub-egress.yaml` limits hub pods in
  `argo` to Kubernetes API, tenant MLflow, DNS, and
  `istio-system/app=istiod`
- `teams/_bases/tenant-core/networkpolicy-mlflow-allow-argo.yaml` allows only
  hub pods in `argo` to reach tenant MLflow pods for model discovery
- `teams/_bases/tenant-core/networkpolicy-mlflow-allow-workflows.yaml` allows
  tenant workflow pods to call MLflow
- `teams/_bases/tenant-core/networkpolicy-mlflow-allow-ingress-mesh.yaml`
  trusts only `istio-system` ingress gateway pods for MLflow UI/API ingress
- `teams/_bases/tenant-core/networkpolicy-mlflow-egress-minio.yaml` keeps
  MLflow artifact access explicit
- `teams/_bases/tenant-core/networkpolicy-serving-runtime-*` isolates rendered
  serving pods behind the `istio-ingressgateway` + `knative-serving/app=activator`
  path and explicit MinIO egress

The sync and prune workflow templates stamp workflow pods with
`platform.ai-ml/network-role=workflow`. `render_inferenceservice.py` stamps the
rendered predictor pod spec with
`platform.ai-ml/network-role=serving-runtime` so the tenant policies can select
those runtime pods deterministically.

Writeback and prune do not hardcode tenant deployment paths. Both scripts read
`writebackRoot` from `teams/<tenant>/tenant-config.yaml` inside the cloned repo.

## Sync Template

`templates/mlflow-tag-sync-workflow.yaml` defines
`ClusterWorkflowTemplate/mlflow-tag-sync`.

Template defaults:

- `alias: champion`
- `url_scheme: http`
- `public_domain: ai-ml.local`
- `challenger_mode: status-only`
- `scripts_configmap: mlflow-tag-sync-scripts`
- `mlflow_secret_name: mlflow-s3-credentials`
- `git_secret_name: mlflow-sync-git-credentials`
- `git_default_branch: auto`
- `dry_run_enabled: "true"`
- `policy_command: ""`

Special deploy logic exists only for alias `challenger`. Any other alias follows
the normal deploy path if resolve succeeds.

## Sync Step Flow

1. `resolve`
   Resolves `(registered_model, alias)` to a concrete MLflow model version,
   reads intent tags, validates JSON shape, and outputs `accepted` or `failed`.
   Emitted reasons include `accepted`, `mlflow_unreachable`,
   `alias_lookup_failed`, `intent_missing`, and `invalid_json`.
2. `state-gate`
   Computes idempotency state keys, but current template behavior always sets
   `changed=true` when resolve succeeded. The emitted reason is
   `evaluated_no_cache`.
3. `decide-deploy`
   Sets `deploy_enabled=false` only when `alias=challenger` and
   `challenger_mode=status-only`. Otherwise a successful resolve produces
   `deploy_enabled=true` with reason `deploy`.
4. `status-accepted`
   Writes MLflow status tags only when `resolve_status=accepted`.
5. `render`
   Calls `render_inferenceservice.py` only when resolve succeeded,
   `state_changed=true`, and `deploy_enabled=true`. Successful render writes
   `render_status=accepted` with reason `rendered`.
6. `status-rendered`
   Writes MLflow status tags only when `render_status=accepted`.
7. `validate`
   Decodes the rendered manifest, optionally attempts server-side dry-run when
   `dry_run_enabled=true` and `kubectl` exists in the container image, and runs
   `policy_command` when it is non-empty. Emitted reasons include `validated`,
   `validated_no_dry_run`, `dry_run_failed`, `policy_denied`, and `skipped`.
8. `writeback`
   Calls `git_writeback.sh` only when validation succeeded.
9. `persist-state`
   Emits `persist_status=skipped` with reason `state_store_disabled`.
10. `finalize`
    Derives the final MLflow tags and optional deployment URL.

## Final Status Mapping

`finalize` is the final source of truth for MLflow sync tags.

- `resolve_status != accepted` -> final `gitops.sync.status=failed`
- `state_changed != true` -> final `gitops.sync.status=applied` with reason
  `no_change`
- `deploy_enabled != true` -> final `gitops.sync.status=applied` with the
  deploy reason, currently `challenger_status_only`
- `render_status != accepted` -> final `gitops.sync.status=failed`
- `validate_status != accepted` -> final `gitops.sync.status=failed`
- `writeback_status = failed` -> final `gitops.sync.status=failed`
- `writeback_status = applied|noop` -> final `gitops.sync.status=applied`

`gitops.sync.commit` is written only when `finalize` receives a non-empty
commit SHA from `writeback`.

`gitops.sync.url` is written only when:

- final status is `applied`
- `deploy_enabled=true`
- `intent_name` is non-empty

`update_mlflow_status.py` enforces monotonic progression for non-failure states:

- `accepted -> rendered -> applied`
- downgrade attempts are ignored
- `failed` is always allowed

## Prune Template

`templates/mlflow-tag-prune-workflow.yaml` defines
`ClusterWorkflowTemplate/mlflow-tag-prune`.

Inputs:

- `tenant`
- `alias`
- `active_models_json`
- `scripts_configmap`
- `git_secret_name`
- `git_default_branch`

Runtime behavior:

- runs with Istio sidecar injection
- mounts the tenant-local script `ConfigMap`
- calls `git_prune_manifests.sh`
- exits non-zero when `prune_status=failed`

`git_prune_manifests.sh`:

- clones the repo with up to three attempts
- reads `writebackRoot` from `teams/<tenant>/tenant-config.yaml`
- scans `writebackRoot/deployments/*.yaml` and `*.yml`
- prunes only manifests managed by this flow, identified by
  `platform.ai-ml/registered-model`
- skips manifests whose `platform.ai-ml/alias` does not match the polled alias
- removes stale entries from the local `kustomization.yaml`

Outputs:

- `prune_status`
- `reason`
- `commit_sha`
- `pruned_paths_json`

## Git Branch Resolution

The current branch selection path is:

- `tenant-config.data.gitDefaultBranch`
- child workflow argument `git_default_branch`
- script argument `--default-branch`
- secret `GIT_DEFAULT_BRANCH` fallback
- script fallback `auto`

When the effective branch is `auto`, writeback and prune resolve the remote
repo's default branch from Gitea `HEAD` before clone/push. The checked-in team
configs and tenant Git secrets currently use `auto`. `bootstrap/gitops-init.sh`
reconciles that remote default branch to the branch it pushes during install.

## Verification

Render this layer:

```bash
kustomize build infra/argo-workflows
```

Trigger one manual hub run:

```bash
kubectl -n argo get cronworkflow mlflow-tag-sync-hub -o json \
| jq '{apiVersion:"argoproj.io/v1alpha1",kind:"Workflow",metadata:{generateName:"mlflow-tag-sync-hub-manual-"},spec:.spec.workflowSpec}' \
| kubectl -n argo create -f -
```

Collect a full workflow snapshot:

```bash
./scripts/troubleshoot-workflow.sh --tenant-namespace ml-team-a
```

Inspect the latest tenant workflow:

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
```

Expected state:

- the hub runs in namespace `argo`
- child sync and prune workflows run in tenant namespaces
- the latest workflow node phases match the current MLflow tag state for that
  model version

## Tenant Integration

Adding another tenant to the shared workflow engine requires:

- `teams/<tenant>/tenant-config.yaml`
- tenant namespace and guardrail layer under `teams/<tenant>/`
- tenant workflow wiring that includes `teams/_bases/workflows`
- tenant `mlflow-sync-git-credentials` secret
- tenant `mlflow-s3-credentials` secret
- tenant writeback path under `apps/tenants/<tenant>/`
- a team root application under `infra/argocd/`

No edits to the shared workflow templates or shared scripts are required when a
tenant is added through the existing contract.

## Related Paths

- `infra/argo-workflows/scripts/README.md`
- `scripts/troubleshoot-workflow.sh`
- `teams/_bases/workflows/`
- `teams/<team>/workflows/`
- `docs/architecture.md`
