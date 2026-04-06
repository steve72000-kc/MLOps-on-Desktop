#!/usr/bin/env sh
set -u

TENANT=""
REGISTERED_MODEL=""
ALIAS=""
TRACE_ID=""
RESOLVED_VERSION=""
INTENT_HASH=""
INTENT_NAME=""
MANIFEST_B64=""
REPO_URL="${GIT_REPO_URL:-}"
DEFAULT_BRANCH="${GIT_DEFAULT_BRANCH:-auto}"
CHALLENGER_MODE="status-only"
OUTPUT_DIR=""

usage() {
  cat <<EOF
Usage: git_writeback.sh \
  --tenant <tenant> \
  --registered-model <registered_model> \
  --alias <alias> \
  --trace-id <trace_id> \
  --resolved-version <version> \
  --intent-hash <sha256> \
  --intent-name <kserve_metadata_name> \
  --manifest-b64 <base64_manifest> \
  --output-dir <dir> \
  [--repo-url <git_repo_url>] \
  [--default-branch <branch>] \
  [--challenger-mode <status-only|preview>]
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tenant) TENANT="$2"; shift 2 ;;
    --registered-model) REGISTERED_MODEL="$2"; shift 2 ;;
    --alias) ALIAS="$2"; shift 2 ;;
    --trace-id) TRACE_ID="$2"; shift 2 ;;
    --resolved-version) RESOLVED_VERSION="$2"; shift 2 ;;
    --intent-hash) INTENT_HASH="$2"; shift 2 ;;
    --intent-name) INTENT_NAME="$2"; shift 2 ;;
    --manifest-b64) MANIFEST_B64="$2"; shift 2 ;;
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --default-branch) DEFAULT_BRANCH="$2"; shift 2 ;;
    --challenger-mode) CHALLENGER_MODE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$OUTPUT_DIR" ]; then
  echo "--output-dir is required" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

write_output() {
  key="$1"
  value="$2"
  printf '%s' "$value" >"${OUTPUT_DIR}/${key}"
}

finish() {
  status="$1"
  reason="$2"
  commit_sha="$3"
  manifest_path="$4"
  write_output writeback_status "$status"
  write_output reason "$reason"
  write_output commit_sha "$commit_sha"
  write_output manifest_path "$manifest_path"
  printf '{"status":"%s","reason":"%s","commit":"%s","path":"%s"}\n' "$status" "$reason" "$commit_sha" "$manifest_path"
  exit 0
}

classify_git_error() {
  log_file="$1"
  if grep -Eiq 'authentication failed|access denied|not authorized|403 forbidden|401 unauthorized' "$log_file"; then
    echo "git_auth_failed"
    return
  fi
  if grep -Eiq 'could not resolve host|connection refused|timed out|no route to host|failed to connect' "$log_file"; then
    echo "git_host_unreachable"
    return
  fi
  echo "git_unknown_error"
}

trim_yaml_value() {
  # shellcheck disable=SC2001
  echo "$1" | sed "s/^['\"]//; s/['\"]$//"
}

extract_yaml_scalar() {
  file="$1"
  key="$2"
  value="$(sed -n "s/^[[:space:]]*${key}:[[:space:]]*//p" "$file" | head -n 1)"
  trim_yaml_value "$value"
}

build_auth_repo_url() {
  url="$1"
  if echo "$url" | grep -Eq '^https?://'; then
    if [ -n "${GIT_USERNAME:-}" ] && [ -n "${GIT_PASSWORD:-}" ]; then
      proto="$(echo "$url" | sed 's#^\(https\?\)://.*#\1#')"
      rest="$(echo "$url" | sed 's#^https\?://##')"
      printf '%s://%s:%s@%s' "$proto" "$GIT_USERNAME" "$GIT_PASSWORD" "$rest"
      return
    fi
  fi
  printf '%s' "$url"
}

resolve_default_branch() {
  requested_branch="$1"
  auth_repo_url="$2"

  if [ -n "$requested_branch" ] && [ "$requested_branch" != "auto" ]; then
    printf '%s' "$requested_branch"
    return
  fi

  if ! git ls-remote --symref "$auth_repo_url" HEAD >/tmp/git-default-branch.log 2>&1; then
    echo "git default branch resolution failed:" >&2
    tail -n 50 /tmp/git-default-branch.log >&2 || true
    reason="$(classify_git_error /tmp/git-default-branch.log)"
    finish "failed" "$reason" "" ""
  fi

  resolved_branch="$(
    awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}' /tmp/git-default-branch.log
  )"
  if [ -z "$resolved_branch" ]; then
    echo "git default branch resolution returned no branch" >&2
    finish "failed" "git_unknown_error" "" ""
  fi

  printf '%s' "$resolved_branch"
}

ensure_kustomization_contains() {
  dir="$1"
  manifest_file="$2"
  kustomization_path="${dir}/kustomization.yaml"

  if [ ! -f "$kustomization_path" ]; then
    cat >"$kustomization_path" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ${manifest_file}
EOF
    return
  fi

  if ! grep -Eq "^[[:space:]]*-[[:space:]]*${manifest_file}$" "$kustomization_path"; then
    printf '\n- %s\n' "$manifest_file" >>"$kustomization_path"
  fi
}

remove_kustomization_entry() {
  dir="$1"
  manifest_file="$2"
  kustomization_path="${dir}/kustomization.yaml"

  if [ ! -f "$kustomization_path" ]; then
    return
  fi

  awk -v target="$manifest_file" '
  {
    trimmed=$0
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed)
    if (trimmed ~ /^-[[:space:]]*/) {
      entry=trimmed
      sub(/^-[[:space:]]*/, "", entry)
      if (entry == target) {
        next
      }
    }
    print $0
  }' "$kustomization_path" >"${kustomization_path}.tmp" && mv "${kustomization_path}.tmp" "$kustomization_path"
}

sanitize_manifest_name() {
  raw_name="$1"
  # Keep filename safe and deterministic from intent metadata.name.
  printf '%s' "$raw_name" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9.-]/-/g; s/^[.-]*//; s/[.-]*$//; s/--*/-/g'
}

if [ "$ALIAS" = "challenger" ] && [ "$CHALLENGER_MODE" = "status-only" ]; then
  echo "writeback skipped: challenger status-only mode"
  finish "noop" "challenger_status_only" "" ""
fi

if [ -z "$REPO_URL" ]; then
  echo "writeback failed: missing repo url"
  finish "failed" "git_repo_missing" "" ""
fi

echo "writeback start tenant=$TENANT model=$REGISTERED_MODEL alias=$ALIAS branch=$DEFAULT_BRANCH"

TMP_DIR="$(mktemp -d)"
REPO_DIR="${TMP_DIR}/repo"
AUTH_REPO_URL="$(build_auth_repo_url "$REPO_URL")"
RESOLVED_BRANCH="$(resolve_default_branch "$DEFAULT_BRANCH" "$AUTH_REPO_URL")"

echo "writeback start tenant=$TENANT model=$REGISTERED_MODEL alias=$ALIAS branch_request=$DEFAULT_BRANCH resolved_branch=$RESOLVED_BRANCH"

if ! git clone --quiet --branch "$RESOLVED_BRANCH" --single-branch "$AUTH_REPO_URL" "$REPO_DIR" >/tmp/git-clone.log 2>&1; then
  echo "git clone failed:" >&2
  tail -n 50 /tmp/git-clone.log >&2 || true
  reason="$(classify_git_error /tmp/git-clone.log)"
  finish "failed" "$reason" "" ""
fi

TENANT_CONFIG_PATH="${REPO_DIR}/teams/${TENANT}/tenant-config.yaml"
if [ ! -f "$TENANT_CONFIG_PATH" ]; then
  finish "failed" "tenant_config_missing" "" ""
fi

WRITEBACK_ROOT="$(extract_yaml_scalar "$TENANT_CONFIG_PATH" "writebackRoot")"

if [ -z "$WRITEBACK_ROOT" ]; then
  finish "failed" "tenant_config_missing" "" ""
fi

SAFE_INTENT_NAME="$(sanitize_manifest_name "$INTENT_NAME")"
TARGET_PATH="${WRITEBACK_ROOT%/}/deployments/inferenceservice.yaml"
if [ -n "$SAFE_INTENT_NAME" ]; then
  TARGET_PATH="${WRITEBACK_ROOT%/}/deployments/${SAFE_INTENT_NAME}.yaml"
fi

if [ "$ALIAS" = "challenger" ] && [ "$CHALLENGER_MODE" = "preview" ]; then
  TARGET_PATH="${WRITEBACK_ROOT%/}/deployments/challenger-inferenceservice.yaml"
  if [ -n "$SAFE_INTENT_NAME" ]; then
    TARGET_PATH="${WRITEBACK_ROOT%/}/deployments/challenger-${SAFE_INTENT_NAME}.yaml"
  fi
fi

if [ -z "$TARGET_PATH" ]; then
  finish "failed" "tenant_config_missing" "" ""
fi

echo "writeback target_path=$TARGET_PATH intent_name=$INTENT_NAME"

TARGET_ABS="${REPO_DIR}/${TARGET_PATH}"
TARGET_DIR="$(dirname "$TARGET_ABS")"
TARGET_FILE="$(basename "$TARGET_ABS")"
mkdir -p "$TARGET_DIR"

if ! printf '%s' "$MANIFEST_B64" | base64 -d >"$TARGET_ABS" 2>/tmp/manifest-decode.log; then
  finish "failed" "render_invalid" "" ""
fi

# Prevent duplicate InferenceService IDs during migration from legacy single-file writeback.
if [ "$TARGET_FILE" != "inferenceservice.yaml" ] && [ "$TARGET_FILE" != "challenger-inferenceservice.yaml" ]; then
  remove_kustomization_entry "$TARGET_DIR" "inferenceservice.yaml"
  remove_kustomization_entry "$TARGET_DIR" "challenger-inferenceservice.yaml"
fi
ensure_kustomization_contains "$TARGET_DIR" "$TARGET_FILE"

cd "$REPO_DIR" || exit 1

git add "$TARGET_PATH" "${TARGET_PATH%/*}/kustomization.yaml"

if git diff --cached --quiet; then
  CURRENT_SHA="$(git rev-parse HEAD)"
  echo "writeback noop: no diff"
  finish "noop" "no_diff" "$CURRENT_SHA" "$TARGET_PATH"
fi

AUTHOR_NAME="${GIT_AUTHOR_NAME:-mlflow-sync-bot}"
AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-mlflow-sync-bot@ai-ml.local}"
COMMIT_MESSAGE="mlflow-sync: tenant=${TENANT} model=${REGISTERED_MODEL} alias=${ALIAS}"

if ! git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" commit -m "$COMMIT_MESSAGE" >/tmp/git-commit.log 2>&1; then
  echo "git commit failed:" >&2
  tail -n 50 /tmp/git-commit.log >&2 || true
  finish "failed" "git_commit_failed" "" "$TARGET_PATH"
fi

NEW_SHA="$(git rev-parse HEAD)"
if ! git push origin "$RESOLVED_BRANCH" >/tmp/git-push.log 2>&1; then
  echo "git push failed:" >&2
  tail -n 50 /tmp/git-push.log >&2 || true
  if grep -Eiq 'non-fast-forward|fetch first|rejected' /tmp/git-push.log; then
    finish "failed" "git_push_conflict" "$NEW_SHA" "$TARGET_PATH"
  fi
  reason="$(classify_git_error /tmp/git-push.log)"
  if [ "$reason" = "git_unknown_error" ]; then
    reason="git_push_failed"
  fi
  finish "failed" "$reason" "$NEW_SHA" "$TARGET_PATH"
fi

finish "applied" "applied" "$NEW_SHA" "$TARGET_PATH"
