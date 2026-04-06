#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF_PATH="bootstrap/migrate-network.sh"

# Edit these two values before running if you want to migrate the repo-wide
# default network. Use only the first three octets; the repo stays on a /24.
EXISTING_NETWORK_PREFIX="${EXISTING_NETWORK_PREFIX:-172.29.0}"
TARGET_NETWORK_PREFIX="${TARGET_NETWORK_PREFIX:-172.30.0}"

DRY_RUN=false
ASSUME_YES=false

usage() {
  cat <<EOF
Usage: ./bootstrap/migrate-network.sh [--dry-run] [--yes]

Rewrites tracked text files in this repo from one /24 network prefix to another.

Edit these variables near the top of the script before running:
  EXISTING_NETWORK_PREFIX=${EXISTING_NETWORK_PREFIX}
  TARGET_NETWORK_PREFIX=${TARGET_NETWORK_PREFIX}

Expected format:
  EXISTING_NETWORK_PREFIX=172.29.0
  TARGET_NETWORK_PREFIX=172.30.0

Options:
  --dry-run   Show the files that would be updated without modifying them.
  --yes       Skip the interactive confirmation prompt.
  -h, --help  Show this help text.

Notes:
  - Only tracked text files are rewritten.
  - .git state, local caches, and binary files are intentionally left alone.
  - After migration, review 'git diff' and then recreate or re-bootstrap the
    cluster so Docker network and static LoadBalancer IPs line up with the repo.
EOF
}

log() {
  printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$*"
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_tools() {
  local cmd
  for cmd in git perl; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
  done
}

validate_prefix() {
  local label="$1"
  local value="$2"
  local octet

  if [[ ! "$value" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]; then
    die "${label} must use the first three octets only (example: 172.29.0)"
  fi

  IFS='.' read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || die "${label} contains a non-numeric octet: $value"
    if (( octet < 0 || octet > 255 )); then
      die "${label} octets must be between 0 and 255: $value"
    fi
  done
}

collect_matching_files() {
  git -C "$ROOT_DIR" grep -IlF "$EXISTING_NETWORK_PREFIX" -- . \
    | grep -v "^${SELF_PATH}$" || true
}

collect_target_collisions() {
  git -C "$ROOT_DIR" grep -IlF "$TARGET_NETWORK_PREFIX" -- . \
    | grep -v "^${SELF_PATH}$" || true
}

print_summary() {
  cat <<EOF
Existing prefix : ${EXISTING_NETWORK_PREFIX}
Target prefix   : ${TARGET_NETWORK_PREFIX}
Existing subnet : ${EXISTING_NETWORK_PREFIX}.0/24
Target subnet   : ${TARGET_NETWORK_PREFIX}.0/24

This will rewrite tracked text files that currently reference the existing
prefix, including static service IPs such as:
  ${EXISTING_NETWORK_PREFIX}.200 -> ${TARGET_NETWORK_PREFIX}.200
  ${EXISTING_NETWORK_PREFIX}.201 -> ${TARGET_NETWORK_PREFIX}.201
  ${EXISTING_NETWORK_PREFIX}.202 -> ${TARGET_NETWORK_PREFIX}.202
  ${EXISTING_NETWORK_PREFIX}.203 -> ${TARGET_NETWORK_PREFIX}.203
  ${EXISTING_NETWORK_PREFIX}.204 -> ${TARGET_NETWORK_PREFIX}.204
  ${EXISTING_NETWORK_PREFIX}.205 -> ${TARGET_NETWORK_PREFIX}.205
EOF
}

confirm_or_exit() {
  local answer
  if $ASSUME_YES; then
    return 0
  fi

  printf "\nProceed with in-place rewrite? [y/N] "
  read -r answer
  case "$answer" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Aborted."
      exit 0
      ;;
  esac
}

rewrite_files() {
  local relpath="$1"
  EXISTING_NETWORK_PREFIX="$EXISTING_NETWORK_PREFIX" \
  TARGET_NETWORK_PREFIX="$TARGET_NETWORK_PREFIX" \
    perl -0pi -e 's/\Q$ENV{EXISTING_NETWORK_PREFIX}\E/$ENV{TARGET_NETWORK_PREFIX}/g' \
    "$ROOT_DIR/$relpath"
}

main() {
  local remaining_output
  local -a files
  local -a collisions
  local relpath

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --yes)
        ASSUME_YES=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  require_tools
  validate_prefix "EXISTING_NETWORK_PREFIX" "$EXISTING_NETWORK_PREFIX"
  validate_prefix "TARGET_NETWORK_PREFIX" "$TARGET_NETWORK_PREFIX"

  if [[ "$EXISTING_NETWORK_PREFIX" == "$TARGET_NETWORK_PREFIX" ]]; then
    die "EXISTING_NETWORK_PREFIX and TARGET_NETWORK_PREFIX must be different"
  fi

  mapfile -t files < <(collect_matching_files)
  if ((${#files[@]} == 0)); then
    echo "No tracked text files contain ${EXISTING_NETWORK_PREFIX}."
    exit 0
  fi

  print_summary

  mapfile -t collisions < <(collect_target_collisions)
  if ((${#collisions[@]} > 0)); then
    log "Warning: target prefix already appears in tracked files"
    printf '%s\n' "${collisions[@]}" | sed 's/^/- /'
  fi

  log "Files to update (${#files[@]})"
  printf '%s\n' "${files[@]}" | sed 's/^/- /'

  if $DRY_RUN; then
    echo
    echo "Dry run only. No files were modified."
    exit 0
  fi

  confirm_or_exit

  log "Rewriting tracked text files"
  for relpath in "${files[@]}"; do
    echo "- ${relpath}"
    rewrite_files "$relpath"
  done

  remaining_output="$(collect_matching_files)"
  if [[ -n "$remaining_output" ]]; then
    log "Warning: some tracked files still contain ${EXISTING_NETWORK_PREFIX}"
    printf '%s\n' "$remaining_output" | sed 's/^/- /'
  fi

  log "Diff summary"
  git -C "$ROOT_DIR" diff --stat -- "${files[@]}" || true

  cat <<EOF

Migration complete.

Next steps:
  1. Review the changes with: git diff
  2. Recreate or re-bootstrap the cluster so Docker and MetalLB use the new /24
  3. Reconcile local GitOps wiring if needed with:
     ./bootstrap/gitops-init.sh

Intentionally not rewritten:
  - .git/config and other files under .git/
  - cached or binary artifacts such as __pycache__ and *.pyc
EOF
}

main "$@"
