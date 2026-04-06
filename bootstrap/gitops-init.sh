#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL_GITEA_ADMIN_USERNAME="gitops-admin"
CANONICAL_GITEA_REPO_NAME="ai-ml"

CLUSTER_NAME="${CLUSTER_NAME:-aiml}"
GITEA_REMOTE_NAME="${GITEA_REMOTE_NAME:-gitea}"
GITEA_REPO_NAME="${GITEA_REPO_NAME:-$CANONICAL_GITEA_REPO_NAME}"
GITEA_REPO_PRIVATE="${GITEA_REPO_PRIVATE:-false}"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
GITEA_SSH_PORT="${GITEA_SSH_PORT:-22}"
GITEA_API_WAIT_SECONDS="${GITEA_API_WAIT_SECONDS:-180}"
GITEA_SSH_STRICT_HOST_KEY_CHECKING="${GITEA_SSH_STRICT_HOST_KEY_CHECKING:-no}"

GITEA_ADMIN_USERNAME="${GITEA_ADMIN_USERNAME:-$CANONICAL_GITEA_ADMIN_USERNAME}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-gitops123}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-gitops-admin@example.local}"

ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-ai-ml-root}"
ARGOCD_APP_NAMESPACE="${ARGOCD_APP_NAMESPACE:-argocd}"
ARGOCD_APP_PATH="${ARGOCD_APP_PATH:-}"
ARGOCD_DEST_NAMESPACE="${ARGOCD_DEST_NAMESPACE:-gitops-demo}"

# Optional override. If unset, script auto-detects common local SSH keys.
GITEA_SSH_PUBLIC_KEY_PATH="${GITEA_SSH_PUBLIC_KEY_PATH:-}"
GITEA_SSH_PRIVATE_KEY_PATH="${GITEA_SSH_PRIVATE_KEY_PATH:-}"

log() {
  printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$*"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command for GitOps init: $1" >&2
    exit 1
  fi
}

validate_repo_identity_alignment() {
  if [[ "$GITEA_ADMIN_USERNAME" != "$CANONICAL_GITEA_ADMIN_USERNAME" ]]; then
    echo "Unsupported GITEA_ADMIN_USERNAME override: ${GITEA_ADMIN_USERNAME}" >&2
    echo "Checked-in Argo CD applications currently expect owner path ${CANONICAL_GITEA_ADMIN_USERNAME}/${CANONICAL_GITEA_REPO_NAME}.git." >&2
    echo "Keep GITEA_ADMIN_USERNAME=${CANONICAL_GITEA_ADMIN_USERNAME} or patch the repo URLs across the repo first." >&2
    exit 1
  fi

  if [[ "$GITEA_REPO_NAME" != "$CANONICAL_GITEA_REPO_NAME" ]]; then
    echo "Unsupported GITEA_REPO_NAME override: ${GITEA_REPO_NAME}" >&2
    echo "Checked-in Argo CD applications currently expect owner path ${CANONICAL_GITEA_ADMIN_USERNAME}/${CANONICAL_GITEA_REPO_NAME}.git." >&2
    echo "Keep GITEA_REPO_NAME=${CANONICAL_GITEA_REPO_NAME} even if your local clone directory name differs." >&2
    exit 1
  fi
}

require_git_repo() {
  if ! git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Expected a git working tree at: $ROOT_DIR" >&2
    exit 1
  fi
  if ! git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "Git repository has no commits yet. Commit once before running bootstrap." >&2
    exit 1
  fi
}

resolve_argocd_app_path() {
  # Allow explicit override to keep behavior predictable.
  if [[ -n "$ARGOCD_APP_PATH" ]]; then
    return
  fi

  local candidate
  for candidate in "clusters/kind/bootstrap"; do
    if [[ -d "${ROOT_DIR}/${candidate}" ]]; then
      ARGOCD_APP_PATH="$candidate"
      return
    fi
  done

  echo "Unable to determine ARGOCD_APP_PATH automatically." >&2
  echo "Expected one of:" >&2
  echo "  - clusters/kind/bootstrap" >&2
  echo "Or set ARGOCD_APP_PATH explicitly before running install." >&2
  exit 1
}

ensure_gitops_path_committed() {
  if [[ ! -d "${ROOT_DIR}/${ARGOCD_APP_PATH}" ]]; then
    echo "Configured Argo app path does not exist in working tree: ${ARGOCD_APP_PATH}" >&2
    exit 1
  fi

  if ! git -C "$ROOT_DIR" ls-tree -r --name-only HEAD -- "${ARGOCD_APP_PATH}/" | grep -q .; then
    echo "Configured Argo app path is not present in the current commit: ${ARGOCD_APP_PATH}" >&2
    echo "Commit the GitOps bootstrap manifests before running install:" >&2
    echo "  git add ${ARGOCD_APP_PATH}" >&2
    echo "  git commit -m \"Add GitOps bootstrap manifests\"" >&2
    exit 1
  fi

  if git -C "$ROOT_DIR" status --porcelain -- "${ARGOCD_APP_PATH}" | grep -q .; then
    echo "Uncommitted changes detected under ${ARGOCD_APP_PATH}." >&2
    echo "Argo CD tracks pushed commits only. Commit changes and rerun." >&2
    exit 1
  fi
}

current_branch() {
  local branch
  branch="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" == "HEAD" ]]; then
    echo "Detached HEAD is not supported for GitOps init. Check out a branch first." >&2
    exit 1
  fi
  echo "$branch"
}

current_upstream_or_empty() {
  git -C "$ROOT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true
}

remote_url_or_empty() {
  local remote_name="$1"
  git -C "$ROOT_DIR" remote get-url "$remote_name" 2>/dev/null || true
}

detect_ssh_key_paths() {
  if [[ -z "$GITEA_SSH_PUBLIC_KEY_PATH" ]]; then
    if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
      GITEA_SSH_PUBLIC_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
    elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
      GITEA_SSH_PUBLIC_KEY_PATH="$HOME/.ssh/id_rsa.pub"
    else
      local generated_key
      generated_key="$HOME/.ssh/ai_ml_gitea"
      mkdir -p "$HOME/.ssh"
      chmod 700 "$HOME/.ssh"
      if [[ ! -f "${generated_key}" ]] || [[ ! -f "${generated_key}.pub" ]]; then
        log "No SSH key detected. Generating dedicated keypair at ${generated_key}"
        ssh-keygen -t ed25519 -N "" -f "${generated_key}" -C "ai-ml-gitea-bootstrap" >/dev/null
      fi
      GITEA_SSH_PUBLIC_KEY_PATH="${generated_key}.pub"
      GITEA_SSH_PRIVATE_KEY_PATH="${generated_key}"
    fi
  fi

  if [[ ! -f "$GITEA_SSH_PUBLIC_KEY_PATH" ]]; then
    echo "Configured SSH public key path does not exist: $GITEA_SSH_PUBLIC_KEY_PATH" >&2
    exit 1
  fi

  if [[ -z "$GITEA_SSH_PRIVATE_KEY_PATH" ]]; then
    local inferred_private
    inferred_private="${GITEA_SSH_PUBLIC_KEY_PATH%.pub}"
    if [[ -f "$inferred_private" ]]; then
      GITEA_SSH_PRIVATE_KEY_PATH="$inferred_private"
    fi
  fi
}

wait_for_service_ip() {
  local namespace="$1"
  local service="$2"
  local timeout="$3"
  local waited=0
  local ip

  while [[ "$waited" -lt "$timeout" ]]; do
    ip="$(kubectl -n "$namespace" get svc "$service" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return
    fi
    sleep 2
    waited=$((waited + 2))
  done

  echo "Timed out waiting for EXTERNAL-IP on service ${namespace}/${service}" >&2
  exit 1
}

wait_for_gitea_api() {
  local gitea_url="$1"
  local timeout="$2"
  local waited=0

  while [[ "$waited" -lt "$timeout" ]]; do
    if curl -sS "${gitea_url}/api/v1/version" >/dev/null 2>&1; then
      return
    fi
    sleep 2
    waited=$((waited + 2))
  done

  echo "Timed out waiting for Gitea API at ${gitea_url}" >&2
  exit 1
}

gitea_api_request() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local body_file
  local status

  body_file="$(mktemp)"
  if [[ -n "$data" ]]; then
    status="$(curl -sS -o "$body_file" -w "%{http_code}" -u "${GITEA_ADMIN_USERNAME}:${GITEA_ADMIN_PASSWORD}" -H "Content-Type: application/json" -X "$method" "$url" -d "$data")"
  else
    status="$(curl -sS -o "$body_file" -w "%{http_code}" -u "${GITEA_ADMIN_USERNAME}:${GITEA_ADMIN_PASSWORD}" -X "$method" "$url")"
  fi
  cat "$body_file"
  rm -f "$body_file"
  echo
  printf "__HTTP_STATUS__%s\n" "$status"
}

ensure_gitea_auth_works() {
  local gitea_url="$1"
  local response
  local status

  response="$(gitea_api_request "GET" "${gitea_url}/api/v1/user")"
  status="$(printf "%s" "$response" | awk -F'__HTTP_STATUS__' 'NF>1{print $2}' | tail -n1)"
  if [[ "$status" != "200" ]]; then
    echo "Failed to authenticate to Gitea API as ${GITEA_ADMIN_USERNAME}." >&2
    echo "Verify GITEA_ADMIN_USERNAME/GITEA_ADMIN_PASSWORD values used during install." >&2
    exit 1
  fi
}

ensure_user_ssh_key() {
  local gitea_url="$1"
  local pub_key_content
  local key_title
  local escaped_key_title
  local escaped_pub_key
  local payload
  local response
  local status

  pub_key_content="$(cat "$GITEA_SSH_PUBLIC_KEY_PATH")"
  key_title="bootstrap-$(hostname)-$(basename "$GITEA_SSH_PUBLIC_KEY_PATH" .pub)"
  escaped_key_title="$(json_escape "$key_title")"
  escaped_pub_key="$(json_escape "$pub_key_content")"
  payload="{\"title\":\"${escaped_key_title}\",\"key\":\"${escaped_pub_key}\"}"

  response="$(gitea_api_request "POST" "${gitea_url}/api/v1/user/keys" "$payload")"
  status="$(printf "%s" "$response" | awk -F'__HTTP_STATUS__' 'NF>1{print $2}' | tail -n1)"

  case "$status" in
    201|422) ;;
    *)
      echo "Failed to add SSH key to Gitea user ${GITEA_ADMIN_USERNAME}. HTTP status: ${status}" >&2
      exit 1
      ;;
  esac
}

ensure_repo_exists() {
  local gitea_url="$1"
  local branch="$2"
  local payload
  local escaped_repo_name
  local escaped_branch
  local response
  local status

  escaped_repo_name="$(json_escape "$GITEA_REPO_NAME")"
  escaped_branch="$(json_escape "$branch")"
  payload="{\"name\":\"${escaped_repo_name}\",\"private\":${GITEA_REPO_PRIVATE},\"auto_init\":false,\"default_branch\":\"${escaped_branch}\"}"
  response="$(gitea_api_request "POST" "${gitea_url}/api/v1/user/repos" "$payload")"
  status="$(printf "%s" "$response" | awk -F'__HTTP_STATUS__' 'NF>1{print $2}' | tail -n1)"

  case "$status" in
    201|409|422) ;;
    *)
      echo "Failed to create or reconcile Gitea repo ${GITEA_REPO_NAME}. HTTP status: ${status}" >&2
      exit 1
      ;;
  esac
}

reconcile_repo_default_branch() {
  local gitea_url="$1"
  local branch="$2"
  local payload
  local escaped_branch
  local response
  local status

  escaped_branch="$(json_escape "$branch")"
  payload="{\"default_branch\":\"${escaped_branch}\"}"
  response="$(gitea_api_request "PATCH" "${gitea_url}/api/v1/repos/${GITEA_ADMIN_USERNAME}/${GITEA_REPO_NAME}" "$payload")"
  status="$(printf "%s" "$response" | awk -F'__HTTP_STATUS__' 'NF>1{print $2}' | tail -n1)"

  case "$status" in
    200|201) ;;
    *)
      echo "Failed to reconcile default branch ${branch} on Gitea repo ${GITEA_REPO_NAME}. HTTP status: ${status}" >&2
      exit 1
      ;;
  esac
}

upsert_local_remote() {
  local remote_url="$1"
  if git -C "$ROOT_DIR" remote get-url "$GITEA_REMOTE_NAME" >/dev/null 2>&1; then
    git -C "$ROOT_DIR" remote set-url "$GITEA_REMOTE_NAME" "$remote_url"
  else
    git -C "$ROOT_DIR" remote add "$GITEA_REMOTE_NAME" "$remote_url"
  fi
}

push_branch() {
  local branch="$1"
  local ssh_cmd="ssh"

  if [[ "$GITEA_SSH_STRICT_HOST_KEY_CHECKING" == "no" ]]; then
    # Local/lab mode: skip host key verification to avoid churn after cluster rebuilds.
    ssh_cmd="${ssh_cmd} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  else
    ssh_cmd="${ssh_cmd} -o StrictHostKeyChecking=accept-new"
  fi

  if [[ -n "$GITEA_SSH_PRIVATE_KEY_PATH" ]] && [[ -f "$GITEA_SSH_PRIVATE_KEY_PATH" ]]; then
    ssh_cmd="${ssh_cmd} -i ${GITEA_SSH_PRIVATE_KEY_PATH}"
  fi

  GIT_SSH_COMMAND="$ssh_cmd" git -C "$ROOT_DIR" push -u "$GITEA_REMOTE_NAME" "$branch"
}

set_branch_upstream() {
  local branch="$1"
  git -C "$ROOT_DIR" branch --set-upstream-to "${GITEA_REMOTE_NAME}/${branch}" "$branch" >/dev/null
}

configure_argocd_repo_and_app() {
  local repo_internal_url="$1"
  local branch="$2"

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: gitea-repo-credentials
  namespace: ${ARGOCD_APP_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${repo_internal_url}
  username: ${GITEA_ADMIN_USERNAME}
  password: ${GITEA_ADMIN_PASSWORD}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ARGOCD_APP_NAME}
  namespace: ${ARGOCD_APP_NAMESPACE}
  finalizers:
  - resources-finalizer.argocd.argoproj.io/foreground
spec:
  project: default
  source:
    repoURL: ${repo_internal_url}
    targetRevision: ${branch}
    path: ${ARGOCD_APP_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGOCD_DEST_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
}

print_summary() {
  local gitea_http_ip="$1"
  local gitea_ssh_ip="$2"
  local branch="$3"
  local previous_upstream="$4"
  local origin_url="$5"
  local repo_ssh_url
  local repo_http_url

  repo_ssh_url="ssh://git@${gitea_ssh_ip}:${GITEA_SSH_PORT}/${GITEA_ADMIN_USERNAME}/${GITEA_REPO_NAME}.git"
  repo_http_url="http://${gitea_http_ip}:${GITEA_HTTP_PORT}/${GITEA_ADMIN_USERNAME}/${GITEA_REPO_NAME}.git"

  log "GitOps wiring complete"
  echo "Cluster context: kind-${CLUSTER_NAME}"
  echo "Local branch pushed: ${branch}"
  echo "Gitea repo default branch: ${branch}"
  echo "Local remote name: ${GITEA_REMOTE_NAME}"
  echo "Local remote URL: ${repo_ssh_url}"
  echo "Previous branch upstream: ${previous_upstream:-<none>}"
  echo "Current branch upstream: ${GITEA_REMOTE_NAME}/${branch}"
  if [[ -n "$origin_url" ]]; then
    echo "Existing origin remote preserved: ${origin_url}"
    echo "Default git push/pull on branch '${branch}' now use in-cluster Gitea."
    echo "Push back to your original clone source explicitly when needed:"
    echo "  git push origin ${branch}"
    echo "If you later want this branch to track origin again after pushing there:"
    echo "  git branch --set-upstream-to origin/${branch} ${branch}"
  else
    echo "No origin remote detected; only the in-cluster GitOps remote is configured locally."
  fi
  echo "Argo app: ${ARGOCD_APP_NAMESPACE}/${ARGOCD_APP_NAME}"
  echo "Gitea repo URL: ${repo_http_url}"
  echo "Gitea admin username: ${GITEA_ADMIN_USERNAME}"
  echo "Gitea admin password: ${GITEA_ADMIN_PASSWORD}"
}

main() {
  require_tool git
  require_tool curl
  require_tool kubectl
  require_tool ssh
  require_tool ssh-keygen
  validate_repo_identity_alignment
  require_git_repo
  resolve_argocd_app_path
  ensure_gitops_path_committed
  detect_ssh_key_paths

  local branch
  local gitea_http_ip
  local gitea_ssh_ip
  local gitea_http_url
  local gitea_repo_ssh_url
  local gitea_repo_internal_url
  local previous_upstream
  local origin_url

  branch="$(current_branch)"
  previous_upstream="$(current_upstream_or_empty)"
  origin_url="$(remote_url_or_empty origin)"
  gitea_http_ip="$(wait_for_service_ip gitea gitea-http "$GITEA_API_WAIT_SECONDS")"
  gitea_ssh_ip="$(wait_for_service_ip gitea gitea-ssh "$GITEA_API_WAIT_SECONDS")"
  gitea_http_url="http://${gitea_http_ip}:${GITEA_HTTP_PORT}"
  gitea_repo_ssh_url="ssh://git@${gitea_ssh_ip}:${GITEA_SSH_PORT}/${GITEA_ADMIN_USERNAME}/${GITEA_REPO_NAME}.git"
  gitea_repo_internal_url="http://gitea-http.gitea.svc.cluster.local:${GITEA_HTTP_PORT}/${GITEA_ADMIN_USERNAME}/${GITEA_REPO_NAME}.git"

  log "Waiting for Gitea API"
  wait_for_gitea_api "$gitea_http_url" "$GITEA_API_WAIT_SECONDS"
  ensure_gitea_auth_works "$gitea_http_url"

  log "Reconciling Gitea SSH key and repository"
  ensure_user_ssh_key "$gitea_http_url"
  ensure_repo_exists "$gitea_http_url" "$branch"

  log "Reconciling local git remote and pushing branch"
  upsert_local_remote "$gitea_repo_ssh_url"
  push_branch "$branch"

  log "Making current branch track the in-cluster GitOps remote"
  set_branch_upstream "$branch"

  log "Reconciling Gitea repo default branch"
  reconcile_repo_default_branch "$gitea_http_url" "$branch"

  log "Configuring Argo CD repository credentials and application"
  configure_argocd_repo_and_app "$gitea_repo_internal_url" "$branch"
  print_summary "$gitea_http_ip" "$gitea_ssh_ip" "$branch" "$previous_upstream" "$origin_url"
}

main "$@"
