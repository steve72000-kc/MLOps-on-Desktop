# Team B Workflow Onboarding

Team-b workflow resources that enable MLflow alias -> GitOps sync and prune for:

- Any registered model in Team-b MLflow
- Workflow template supports aliases `champion` and `challenger`

Repo defaults keep team-b disabled:
- `infra/argocd/kustomization.yaml` comments out
  `application-ml-team-b-root.yaml`, so Argo CD does not create the team-b root
  app
- `teams/kustomization.yaml` also comments out `ml-team-b`, so aggregate local
  builds skip it by default
- repo validation still covers Team-b because `./scripts/validate.sh` builds
  every tracked `kustomization.yaml`, including the Team-b paths

## Files in This Folder

- `kustomization.yaml`
  - Includes the shared tenant workflow base plus Team-b Git credentials.
- `secret-mlflow-sync-git-credentials.yaml`
  - Git clone/push credentials and default branch for sync/prune writeback.

Shared workflow scripts are centrally owned in:

- `infra/argo-workflows/scripts/*`

Shared tenant workflow runtime is applied from:

- `teams/_bases/workflows/`

Authoritative Team-b tenant metadata lives in:

- `teams/ml-team-b/tenant-config.yaml`

## Required MLflow Model Version Tags

- `kserve.intent.mode=inline|artifact-ref`
- Inline mode:
  - `kserve.intent.payload=<json-string>`
- Artifact-ref mode:
  - `kserve.intent.ref=artifacts:/deploy-intent.json`

If missing or invalid, resolve step returns failure reasons such as `intent_missing` or `invalid_json`.

## Branch Configuration (Must Match Repo Reality)

Team-b writeback now defaults to `auto`, which resolves the current default
branch from the in-cluster Gitea repo. `bootstrap/gitops-init.sh` reconciles
that default branch to the branch pushed during install. If you pin an explicit
branch instead, keep all sources aligned:

Your local clone directory name does not matter. Workflow writeback still uses
the canonical in-cluster repo path `gitops-admin/ai-ml.git` so the checked-in
Argo CD and workflow references stay stable.

- `teams/ml-team-b/tenant-config.yaml`:
  - `gitDefaultBranch: auto`
- `secret-mlflow-sync-git-credentials.yaml`:
  - `GIT_DEFAULT_BRANCH: auto`
  - `GIT_REPO_URL: http://gitea-http.gitea.svc.cluster.local:3000/gitops-admin/ai-ml.git`
- Shared workflow defaults and cron dispatcher:
  - `infra/argo-workflows/templates/mlflow-tag-sync-workflow.yaml`
  - `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`

If these drift (for example one side still uses `main`), writeback can fail with clone errors and final reason `git_unknown_error`.

## Scheduling and Triggering

Polling/dispatch is centralized:

- `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`
- After Team-b is enabled, the hub discovers it automatically from the labeled
  `tenant-config` ConfigMap in namespace `ml-team-b`.
- Hub dispatches:
  - one `mlflow-tag-prune` workflow per tenant poll
  - one `mlflow-tag-sync` workflow per discovered model
- If discovery output is `[]`, sync dispatch is skipped and prune-only execution is expected.

Manual trigger:

```bash
kubectl -n argo get cronworkflow mlflow-tag-sync-hub -o json \
| jq '{apiVersion:"argoproj.io/v1alpha1",kind:"Workflow",metadata:{generateName:"mlflow-tag-sync-hub-manual-"},spec:.spec.workflowSpec}' \
| kubectl -n argo create -f -
```

## Fast Team-B Debug Commands

Generate a full hub/sync/prune snapshot first:

```bash
./scripts/troubleshoot-workflow.sh --tenant-namespace ml-team-b
```

Then drill into latest specific workflow(s) if needed.

Get latest team-b workflow and show node phases:

```bash
WF="$(kubectl -n ml-team-b get wf --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name --no-headers | tail -n 1)"
kubectl -n ml-team-b get wf "$WF" -o json | jq -r '
  .status.phase as $p |
  .status.message as $m |
  "workflow_phase=\($p)\nworkflow_message=\($m)\n",
  (.status.nodes | to_entries[] |
    [.value.displayName, .value.phase, (.value.templateName // ""), (.value.message // "")]
    | @tsv)
'
```

Show logs for all pods in that workflow:

```bash
for p in $(kubectl -n ml-team-b get pods -l workflows.argoproj.io/workflow="$WF" -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $p (main) ==="
  kubectl -n ml-team-b logs "$p" -c main --tail=200 || true
done
```

## Common Outcome Signals

- `gitops.sync.status=applied`
  - Successful finalization; commit/url should be set when deploy was enabled.
- `gitops.sync.status=failed`
  - Check `gitops.sync.reason` and corresponding node logs.
- Temporary intermediate statuses:
  - `accepted`, `rendered` (before `finalize` completes).

Prune outcomes:
- `prune_status=applied`
  - stale managed manifests were removed and pushed.
- `prune_status=noop` with reason `no_stale_manifests`
  - no stale managed files found for this poll.
- `prune_status=failed`
  - see prune pod `main` logs (git clone/push errors are printed).

Script ownership is centralized in infra and mounted through the shared tenant workflow base; team-b does not maintain workflow script copies.

Manifest stability note:
- `trace_id` remains in MLflow status tags for run correlation.
- rendered `InferenceService` YAML intentionally does not persist `platform.ai-ml/trace-id`, preventing no-op sync cycles from churning KServe revisions.
