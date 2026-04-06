#!/usr/bin/env sh
set -u

TENANT=""
ALIAS="champion"
ACTIVE_MODELS_JSON="[]"
REPO_URL="${GIT_REPO_URL:-}"
DEFAULT_BRANCH="${GIT_DEFAULT_BRANCH:-auto}"
OUTPUT_DIR=""

usage() {
  cat <<EOF
Usage: git_prune_manifests.sh \
  --tenant <tenant> \
  --alias <alias> \
  --active-models-json <json_array> \
  --output-dir <dir> \
  [--repo-url <git_repo_url>] \
  [--default-branch <branch>]
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tenant) TENANT="$2"; shift 2 ;;
    --alias) ALIAS="$2"; shift 2 ;;
    --active-models-json) ACTIVE_MODELS_JSON="$2"; shift 2 ;;
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --default-branch) DEFAULT_BRANCH="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$TENANT" ]; then
  echo "--tenant is required" >&2
  exit 1
fi

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
  pruned_paths_json="$4"
  write_output prune_status "$status"
  write_output reason "$reason"
  write_output commit_sha "$commit_sha"
  write_output pruned_paths_json "$pruned_paths_json"
  printf '{"status":"%s","reason":"%s","commit":"%s","pruned_paths":%s}\n' "$status" "$reason" "$commit_sha" "$pruned_paths_json"
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
    finish "failed" "$reason" "" "[]"
  fi

  resolved_branch="$(
    awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}' /tmp/git-default-branch.log
  )"
  if [ -z "$resolved_branch" ]; then
    echo "git default branch resolution returned no branch" >&2
    finish "failed" "git_unknown_error" "" "[]"
  fi

  printf '%s' "$resolved_branch"
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

normalize_active_models() {
  # Expected shape: ["model.a","model.b"].
  # Model names are registry identifiers and do not include commas.
  printf '%s' "$ACTIVE_MODELS_JSON" \
    | tr -d '[]' \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed 's/^"//; s/"$//' \
    | sed "s/^'//; s/'$//" \
    | sed '/^$/d' \
    | sort -u
}

extract_manifest_scalar() {
  file_path="$1"
  field_name="$2"
  awk -v key="$field_name" '
    index($0, key) > 0 {
      value=$0
      sub(/^[^:]*:[[:space:]]*/, "", value)
      gsub(/["'\'',]/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$file_path"
}

ACTIVE_MODELS_FILE=""
is_model_active() {
  model="$1"
  if [ ! -s "$ACTIVE_MODELS_FILE" ]; then
    return 1
  fi
  grep -Fxq "$model" "$ACTIVE_MODELS_FILE"
}

pruned_paths_json() {
  file_path="$1"
  if [ ! -s "$file_path" ]; then
    echo "[]"
    return
  fi

  awk '
    BEGIN { printf "[" }
    {
      gsub(/\\/,"\\\\")
      gsub(/"/,"\\\"")
      if (NR > 1) {
        printf ","
      }
      printf "\"%s\"", $0
    }
    END { printf "]" }
  ' "$file_path"
}

if [ -z "$REPO_URL" ]; then
  echo "prune failed: missing repo url"
  finish "failed" "git_repo_missing" "" "[]"
fi

TMP_DIR="$(mktemp -d)"
REPO_DIR="${TMP_DIR}/repo"
AUTH_REPO_URL="$(build_auth_repo_url "$REPO_URL")"
RESOLVED_BRANCH="$(resolve_default_branch "$DEFAULT_BRANCH" "$AUTH_REPO_URL")"

echo "prune start tenant=$TENANT alias=$ALIAS branch_request=$DEFAULT_BRANCH resolved_branch=$RESOLVED_BRANCH"

clone_ok=0
attempt=1
max_attempts=3
while [ "$attempt" -le "$max_attempts" ]; do
  if git clone --quiet --branch "$RESOLVED_BRANCH" --single-branch "$AUTH_REPO_URL" "$REPO_DIR" >/tmp/git-clone.log 2>&1; then
    clone_ok=1
    break
  fi

  echo "git clone failed attempt=${attempt}/${max_attempts}:" >&2
  tail -n 50 /tmp/git-clone.log >&2 || true

  if [ "$attempt" -lt "$max_attempts" ]; then
    rm -rf "$REPO_DIR"
    sleep $((attempt * 2))
  fi
  attempt=$((attempt + 1))
done

if [ "$clone_ok" -ne 1 ]; then
  reason="$(classify_git_error /tmp/git-clone.log)"
  finish "failed" "$reason" "" "[]"
fi

TENANT_CONFIG_PATH="${REPO_DIR}/teams/${TENANT}/tenant-config.yaml"
if [ ! -f "$TENANT_CONFIG_PATH" ]; then
  finish "failed" "tenant_config_missing" "" "[]"
fi

WRITEBACK_ROOT="$(extract_yaml_scalar "$TENANT_CONFIG_PATH" "writebackRoot")"
if [ -z "$WRITEBACK_ROOT" ]; then
  finish "failed" "tenant_config_missing" "" "[]"
fi

TARGET_DIR="${REPO_DIR}/${WRITEBACK_ROOT%/}/deployments"

ACTIVE_MODELS_FILE="${TMP_DIR}/active-models.txt"
normalize_active_models >"$ACTIVE_MODELS_FILE"
echo "prune active_models_count=$(wc -l < "$ACTIVE_MODELS_FILE" | tr -d ' ')"

PRUNED_PATHS_FILE="${TMP_DIR}/pruned-paths.txt"
: >"$PRUNED_PATHS_FILE"
changed=0

prune_candidate_file() {
  candidate_abs="$1"
  if [ ! -f "$candidate_abs" ]; then
    return
  fi

  candidate_base="$(basename "$candidate_abs")"
  case "$candidate_base" in
    kustomization.yaml|kustomization.yml)
      return
      ;;
  esac

  registered_model="$(extract_manifest_scalar "$candidate_abs" "platform.ai-ml/registered-model")"
  if [ -z "$registered_model" ]; then
    return
  fi

  candidate_alias="$(extract_manifest_scalar "$candidate_abs" "platform.ai-ml/alias")"
  if [ -n "$candidate_alias" ] && [ "$candidate_alias" != "$ALIAS" ]; then
    return
  fi

  if is_model_active "$registered_model"; then
    return
  fi

  candidate_rel="${candidate_abs#$REPO_DIR/}"
  echo "prune removing stale manifest path=$candidate_rel registered_model=$registered_model"
  rm -f "$candidate_abs"
  remove_kustomization_entry "$(dirname "$candidate_abs")" "$candidate_base"
  printf '%s\n' "$candidate_rel" >>"$PRUNED_PATHS_FILE"
  changed=1
}

if [ -d "$TARGET_DIR" ]; then
  for manifest_path in "$TARGET_DIR"/*.yaml "$TARGET_DIR"/*.yml; do
    [ -e "$manifest_path" ] || continue
    prune_candidate_file "$manifest_path"
  done
else
  echo "prune note: deployments directory not found for tenant=$TENANT"
fi

cd "$REPO_DIR" || exit 1
git add -A

CURRENT_SHA="$(git rev-parse HEAD)"
PRUNED_JSON="$(pruned_paths_json "$PRUNED_PATHS_FILE")"

if [ "$changed" -eq 0 ] || git diff --cached --quiet; then
  echo "prune noop: no stale manifests for alias=$ALIAS"
  finish "noop" "no_stale_manifests" "$CURRENT_SHA" "$PRUNED_JSON"
fi

AUTHOR_NAME="${GIT_AUTHOR_NAME:-mlflow-sync-bot}"
AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-mlflow-sync-bot@ai-ml.local}"
COMMIT_MESSAGE="mlflow-prune: tenant=${TENANT} alias=${ALIAS}"

if ! git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" commit -m "$COMMIT_MESSAGE" >/tmp/git-commit.log 2>&1; then
  echo "git commit failed:" >&2
  tail -n 50 /tmp/git-commit.log >&2 || true
  finish "failed" "git_commit_failed" "" "$PRUNED_JSON"
fi

NEW_SHA="$(git rev-parse HEAD)"
if ! git push origin "$RESOLVED_BRANCH" >/tmp/git-push.log 2>&1; then
  echo "git push failed:" >&2
  tail -n 50 /tmp/git-push.log >&2 || true
  if grep -Eiq 'non-fast-forward|fetch first|rejected' /tmp/git-push.log; then
    finish "failed" "git_push_conflict" "$NEW_SHA" "$PRUNED_JSON"
  fi
  reason="$(classify_git_error /tmp/git-push.log)"
  if [ "$reason" = "git_unknown_error" ]; then
    reason="git_push_failed"
  fi
  finish "failed" "$reason" "$NEW_SHA" "$PRUNED_JSON"
fi

finish "applied" "applied" "$NEW_SHA" "$PRUNED_JSON"
