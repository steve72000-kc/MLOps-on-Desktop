#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

detect_kustomize_renderer() {
  if command -v kustomize >/dev/null 2>&1; then
    printf '%s' "kustomize"
    return
  fi

  if command -v kubectl >/dev/null 2>&1; then
    printf '%s' "kubectl"
  fi
}

build_kustomization() {
  renderer="$1"
  dir="$2"

  case "$renderer" in
    kustomize)
      kustomize build --load-restrictor LoadRestrictionsNone "$dir" >/dev/null
      ;;
    kubectl)
      kubectl kustomize --load-restrictor=LoadRestrictionsNone "$dir" >/dev/null
      ;;
    *)
      echo "Unsupported kustomize renderer: $renderer" >&2
      return 1
      ;;
  esac
}

cd "$ROOT_DIR"

log "Checking shell syntax"
bash -n bootstrap/*.sh scripts/*.sh

if command -v shellcheck >/dev/null 2>&1; then
  log "Running shellcheck"
  shellcheck bootstrap/*.sh scripts/*.sh
else
  log "Skipping shellcheck (not installed)"
fi

log "Compiling Python scripts"
python3 -m py_compile \
  infra/argo-workflows/scripts/*.py \
  teams/ml-team-a/mlflow/scripts/*.py \
  tests/*.py

log "Running unit tests"
python3 -m unittest discover -s tests -v

KUSTOMIZE_RENDERER="$(detect_kustomize_renderer)"
if [ -n "$KUSTOMIZE_RENDERER" ]; then
  if [ "$KUSTOMIZE_RENDERER" = "kustomize" ]; then
    log "Building tracked kustomize roots with standalone kustomize"
  else
    log "Building tracked kustomize roots with kubectl kustomize"
  fi

  while IFS= read -r kustomization; do
    dir="$(dirname "$kustomization")"
    printf ' - %s\n' "$dir"
    build_kustomization "$KUSTOMIZE_RENDERER" "$dir"
  done < <(git ls-files | awk '/(^|\/)kustomization\.yaml$/ {print}' | sort)
else
  log "Skipping kustomize validation (neither kustomize nor kubectl is installed)"
fi

log "Validation complete"
