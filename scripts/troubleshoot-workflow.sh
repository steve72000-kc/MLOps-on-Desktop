#!/usr/bin/env sh
set -eu

HUB_NS="argo"
TENANT_NS="ml-team-a"
HUB_CRON="mlflow-tag-sync-hub"
LOG_LINES=300
OUTPUT_DIR=""

usage() {
  cat <<EOF
Usage: scripts/troubleshoot-workflow.sh [options]

Options:
  -h, --help                 Show help
  --hub-namespace <ns>       Hub workflow namespace (default: argo)
  --tenant-namespace <ns>    Tenant workflow namespace (default: ml-team-a)
  --hub-cron <name>          Hub CronWorkflow name (default: mlflow-tag-sync-hub)
  --log-lines <n>            Log tail lines per pod/container (default: 300)
  --output-dir <dir>         Output directory (default: /tmp/ai-ml-sync-troubleshoot-<ts>)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --hub-namespace)
      HUB_NS="$2"
      shift 2
      ;;
    --tenant-namespace)
      TENANT_NS="$2"
      shift 2
      ;;
    --hub-cron)
      HUB_CRON="$2"
      shift 2
      ;;
    --log-lines)
      LOG_LINES="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need_cmd kubectl
need_cmd jq
need_cmd rg

if [ -z "$OUTPUT_DIR" ]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  OUTPUT_DIR="/tmp/ai-ml-sync-troubleshoot-${ts}"
fi
mkdir -p "$OUTPUT_DIR"
REPORT_FILE="${OUTPUT_DIR}/summary.txt"
: >"$REPORT_FILE"

log() {
  printf '%s\n' "$*" | tee -a "$REPORT_FILE"
}

section() {
  log ""
  log "===================================================================="
  log "$1"
  log "===================================================================="
}

run_cmd() {
  title="$1"
  cmd="$2"
  section "$title"
  log "\$ $cmd"
  sh -c "$cmd" 2>&1 | tee -a "$REPORT_FILE" || true
}

save_json() {
  path="$1"
  cmd="$2"
  sh -c "$cmd" >"$path" 2>/dev/null || true
}

section "Context"
log "hub_namespace=$HUB_NS"
log "tenant_namespace=$TENANT_NS"
log "hub_cron=$HUB_CRON"
log "log_lines=$LOG_LINES"
log "output_dir=$OUTPUT_DIR"
log "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

run_cmd "Hub CronWorkflow Snapshot" "kubectl -n \"$HUB_NS\" get cronworkflow \"$HUB_CRON\" -o yaml | rg -n \"schedule|timezone|tracking_uri|registered_model|alias|challenger_mode|suspend\""

HWF="$(kubectl -n "$HUB_NS" get wf --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name --no-headers | tail -n 1 || true)"
if [ -n "$HWF" ]; then
  save_json "${OUTPUT_DIR}/hub-workflow.json" "kubectl -n \"$HUB_NS\" get wf \"$HWF\" -o json"
  run_cmd "Latest Hub Workflow" "kubectl -n \"$HUB_NS\" get wf \"$HWF\" -o wide"
  run_cmd "Hub Node Phases" "kubectl -n \"$HUB_NS\" get wf \"$HWF\" -o json | jq -r '.status.phase as \$p | \"hub_phase=\\(\$p)\", (.status.nodes | to_entries[] | [.value.displayName,.value.phase, (.value.message // \"\")] | @tsv)'"
  run_cmd "Hub Discover Output Parameter" "kubectl -n \"$HUB_NS\" get wf \"$HWF\" -o json | jq -r '.status.nodes | to_entries[] | select(.value.displayName==\"discover-models\") | .value.outputs.parameters[]? | select(.name==\"registered_models_json\") | .value'"
  run_cmd "Hub Pods" "kubectl -n \"$HUB_NS\" get pods -l workflows.argoproj.io/workflow=\"$HWF\" -o wide"
  run_cmd "Argo Namespace NetworkPolicies" "kubectl -n \"$HUB_NS\" get networkpolicy -o wide"

  for p in $(kubectl -n "$HUB_NS" get pods -l workflows.argoproj.io/workflow="$HWF" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    run_cmd "Hub Pod Describe: $p" "kubectl -n \"$HUB_NS\" describe pod \"$p\""
    run_cmd "Hub Pod Logs: $p (main)" "kubectl -n \"$HUB_NS\" logs \"$p\" -c main --tail=\"$LOG_LINES\""
    run_cmd "Hub Pod Logs: $p (wait)" "kubectl -n \"$HUB_NS\" logs \"$p\" -c wait --tail=\"$LOG_LINES\""
    run_cmd "Hub Pod Logs: $p (istio-proxy)" "kubectl -n \"$HUB_NS\" logs \"$p\" -c istio-proxy --tail=\"$LOG_LINES\""
  done
else
  section "Latest Hub Workflow"
  log "No workflow found in namespace $HUB_NS"
fi

TWF="$(kubectl -n "$TENANT_NS" get wf --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name --no-headers | rg '^mlflow-tag-sync-' | tail -n 1 || true)"
if [ -n "$TWF" ]; then
  save_json "${OUTPUT_DIR}/tenant-workflow.json" "kubectl -n \"$TENANT_NS\" get wf \"$TWF\" -o json"
  run_cmd "Latest Tenant Workflow" "kubectl -n \"$TENANT_NS\" get wf \"$TWF\" -o wide"
  run_cmd "Tenant Workflow Args" "kubectl -n \"$TENANT_NS\" get wf \"$TWF\" -o json | jq -r '.spec.arguments.parameters[] | [.name, .value] | @tsv'"
  run_cmd "Tenant Node Phases" "kubectl -n \"$TENANT_NS\" get wf \"$TWF\" -o json | jq -r '.status.phase as \$p | \"tenant_phase=\\(\$p)\", (.status.nodes | to_entries[] | [.value.displayName,.value.phase, (.value.message // \"\")] | @tsv)'"
  run_cmd "Tenant Pods" "kubectl -n \"$TENANT_NS\" get pods -l workflows.argoproj.io/workflow=\"$TWF\" -o wide"

  for p in $(kubectl -n "$TENANT_NS" get pods -l workflows.argoproj.io/workflow="$TWF" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    run_cmd "Tenant Pod Logs: $p (main)" "kubectl -n \"$TENANT_NS\" logs \"$p\" -c main --tail=\"$LOG_LINES\""
    run_cmd "Tenant Pod Logs: $p (wait)" "kubectl -n \"$TENANT_NS\" logs \"$p\" -c wait --tail=\"$LOG_LINES\""
  done
else
  section "Latest Tenant Workflow"
  log "No mlflow-tag-sync workflow found in namespace $TENANT_NS"
fi

PWF="$(kubectl -n "$TENANT_NS" get wf --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name --no-headers | rg '^mlflow-tag-prune-' | tail -n 1 || true)"
if [ -n "$PWF" ]; then
  save_json "${OUTPUT_DIR}/tenant-prune-workflow.json" "kubectl -n \"$TENANT_NS\" get wf \"$PWF\" -o json"
  run_cmd "Latest Tenant Prune Workflow" "kubectl -n \"$TENANT_NS\" get wf \"$PWF\" -o wide"
  run_cmd "Tenant Prune Workflow Args" "kubectl -n \"$TENANT_NS\" get wf \"$PWF\" -o json | jq -r '.spec.arguments.parameters[] | [.name, .value] | @tsv'"
  run_cmd "Tenant Prune Node Phases" "kubectl -n \"$TENANT_NS\" get wf \"$PWF\" -o json | jq -r '.status.phase as \$p | \"tenant_prune_phase=\\(\$p)\", (.status.nodes | to_entries[] | [.value.displayName,.value.phase, (.value.message // \"\")] | @tsv)'"
  run_cmd "Tenant Prune Pods" "kubectl -n \"$TENANT_NS\" get pods -l workflows.argoproj.io/workflow=\"$PWF\" -o wide"

  for p in $(kubectl -n "$TENANT_NS" get pods -l workflows.argoproj.io/workflow="$PWF" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    run_cmd "Tenant Prune Pod Logs: $p (main)" "kubectl -n \"$TENANT_NS\" logs \"$p\" -c main --tail=\"$LOG_LINES\""
    run_cmd "Tenant Prune Pod Logs: $p (wait)" "kubectl -n \"$TENANT_NS\" logs \"$p\" -c wait --tail=\"$LOG_LINES\""
  done
else
  section "Latest Tenant Prune Workflow"
  log "No mlflow-tag-prune workflow found in namespace $TENANT_NS"
fi

run_cmd "Tenant InferenceServices" "kubectl -n \"$TENANT_NS\" get inferenceservice -o wide"
run_cmd "Tenant KServe/Knative Services" "kubectl -n \"$TENANT_NS\" get ksvc -o wide"
run_cmd "Tenant NetworkPolicies" "kubectl -n \"$TENANT_NS\" get networkpolicy -o wide"
run_cmd "Tenant Git Secret (sanitized)" "kubectl -n \"$TENANT_NS\" get secret mlflow-sync-git-credentials -o json | jq -r '{name:.metadata.name, GIT_REPO_URL:(.data.GIT_REPO_URL // \"\" | @base64d), GIT_DEFAULT_BRANCH:(.data.GIT_DEFAULT_BRANCH // \"\" | @base64d), GIT_USERNAME:(.data.GIT_USERNAME // \"\" | @base64d)}'"
run_cmd "Tenant Netpol Gitea Rule" "kubectl -n \"$TENANT_NS\" get networkpolicy tenant-default -o yaml | rg -n \"gitea|port: 3000|podSelector|namespaceSelector\""
run_cmd "Gitea Service" "kubectl -n gitea get svc gitea-http -o wide"
run_cmd "Gitea Service Ports/Selector" "kubectl -n gitea get svc gitea-http -o yaml | rg -n \"name:|port:|targetPort:|selector:|clusterIP:\""
run_cmd "Gitea Endpoints" "kubectl -n gitea get endpoints gitea-http -o wide"
run_cmd "Gitea Pods (labels)" "kubectl -n gitea get pods -o wide --show-labels"
run_cmd "Recent Tenant Events" "kubectl -n \"$TENANT_NS\" get events --sort-by=.lastTimestamp | tail -n 80"

section "Done"
log "Troubleshooting report saved to: $REPORT_FILE"
log "Raw workflow JSON: ${OUTPUT_DIR}/hub-workflow.json, ${OUTPUT_DIR}/tenant-workflow.json, and ${OUTPUT_DIR}/tenant-prune-workflow.json"
