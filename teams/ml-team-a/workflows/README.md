# Team A Workflows

`teams/ml-team-a/workflows/` contains Team-a workflow prerequisites for the
shared MLflow alias -> GitOps sync and prune path.

## Configuration

- tenant metadata is defined in `teams/ml-team-a/tenant-config.yaml`
- `syncAlias` is `champion`
- `challengerMode` is `status-only`
- the scheduled hub poll is centralized in
  `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`

## Files

- `kustomization.yaml` applies the shared tenant workflow base plus Team-a Git
  credentials
- `secret-mlflow-sync-git-credentials.yaml` contains the Git clone/push
  credentials, repository URL, and default branch used by writeback and prune

## Ownership

- shared tenant workflow runtime is applied from `teams/_bases/workflows/`
- shared workflow scripts are centrally owned in
  `infra/argo-workflows/scripts/`
- this directory is repo-owned tenant workflow wiring, not a Team-a authoring
  surface
- Team-a participates in the deployment path through MLflow model registration,
  alias assignment, and deployment intent metadata; workflow engine behavior
  and script logic are platform-owned

## Automatic Sync Contract

- the registered model version must be assigned the alias `champion`
- the model version must include `kserve.intent.mode=inline|artifact-ref`
- inline mode requires `kserve.intent.payload=<json-string>`
- artifact-ref mode requires `kserve.intent.ref=artifacts:/deploy-intent.json`
- models without the configured alias or without valid intent tags are not
  discovered by the hub and do not enter the automatic deployment path
- missing or invalid intent metadata produces resolve failures such as
  `intent_missing` or `invalid_json`

## Branch Configuration

- Team-a now defaults writeback to `auto`
- `teams/ml-team-a/tenant-config.yaml` sets `gitDefaultBranch: auto`
- `secret-mlflow-sync-git-credentials.yaml` sets `GIT_DEFAULT_BRANCH: auto`
- shared workflow templates also default `git_default_branch` to `auto`
- `auto` resolves the current default branch from the in-cluster Gitea repo,
  which `bootstrap/gitops-init.sh` reconciles to the branch pushed during install
- your local clone directory name does not matter; workflow writeback still
  targets the canonical in-cluster repo path `gitops-admin/ai-ml.git`

## Scheduling And Triggering

- polling and dispatch are centralized in
  `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`
- hub discovery starts from the labeled `tenant-config` `ConfigMap` in
  namespace `ml-team-a`
- for Team-a, the hub queries MLflow using alias `champion` and dispatches:
  - one `mlflow-tag-prune` workflow per tenant poll
  - one `mlflow-tag-sync` workflow per discovered model
- if discovery output is `[]`, sync dispatch is skipped and prune-only
  execution is expected

### Manual Trigger

```bash
kubectl -n argo get cronworkflow mlflow-tag-sync-hub -o json \
| jq '{apiVersion:"argoproj.io/v1alpha1",kind:"Workflow",metadata:{generateName:"mlflow-tag-sync-hub-manual-"},spec:.spec.workflowSpec}' \
| kubectl -n argo create -f -
```

## Debug Commands

### Full Workflow Snapshot

Run the repo troubleshooting helper from the repo root.

```bash
./scripts/troubleshoot-workflow.sh --tenant-namespace ml-team-a
```

### Latest Workflow Summary

Show the latest Team-a workflow phase, workflow message, and node-level phases.

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

### Workflow Pod Logs

Print the recent `main` container logs for every pod in the selected workflow.

```bash
for p in $(kubectl -n ml-team-a get pods -l workflows.argoproj.io/workflow="$WF" -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $p (main) ==="
  kubectl -n ml-team-a logs "$p" -c main --tail=200 || true
done
```

### MLflow Sync Tags

Query Team-a registered models in MLflow and print the current sync tags for
the `champion` alias.

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
]

models = sorted(
    rm.name
    for rm in client.search_registered_models()
    if rm.name.startswith(team_prefix)
)

for model in models:
    try:
        mv = client.get_model_version_by_alias(model, alias)
    except Exception as exc:
        print(model, "->", exc)
        continue
    print("\nmodel:", model, "version:", mv.version)
    for k in tag_keys:
        print(" ", k, "=", mv.tags.get(k))
PY
```

## Outcome Signals

- `gitops.sync.status=applied` indicates successful finalization; commit and
  URL should be set when deploy was enabled
- `gitops.sync.status=failed` indicates failure; inspect
  `gitops.sync.reason` and the corresponding node logs
- intermediate statuses include `accepted` and `rendered`
- `prune_status=applied` indicates stale managed manifests were removed and
  pushed
- `prune_status=noop` with reason `no_stale_manifests` indicates no stale
  managed files for that poll
- `prune_status=failed` indicates prune failure; inspect prune pod `main` logs

## Manifest Stability

- `trace_id` is written to MLflow status tags for workflow correlation
- rendered `InferenceService` manifests do not persist
  `platform.ai-ml/trace-id`, which avoids no-op revision churn
