#!/usr/bin/env sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MINIO_HOST_DATA_DIR="${MINIO_HOST_DATA_DIR:-${ROOT_DIR}/.local/minio-data}"
MINIO_HOST_DATA_MODE="${MINIO_HOST_DATA_MODE:-0777}"
MLFLOW_TENANTS="${MLFLOW_TENANTS:-ml-team-a ml-team-b}"
STATE_ROOT_DIR="$(dirname "${MINIO_HOST_DATA_DIR}")"
TARGET_OWNER_UID="${SUDO_UID:-$(id -u)}"
TARGET_OWNER_GID="${SUDO_GID:-$(id -g)}"

restore_owner() {
  if [ "$(id -u)" -ne 0 ] || [ -z "${SUDO_UID:-}" ] || [ -z "${SUDO_GID:-}" ]; then
    return 0
  fi

  # Running through sudo may create the repo-local state root as root on a fresh clone.
  chown "${TARGET_OWNER_UID}:${TARGET_OWNER_GID}" "${STATE_ROOT_DIR}" || true
  chown -R "${TARGET_OWNER_UID}:${TARGET_OWNER_GID}" "${MINIO_HOST_DATA_DIR}" || true
}

if [ "${1:-}" != "--force" ]; then
  echo "Refusing to delete MinIO data without explicit confirmation."
  echo "Usage: ./bootstrap/reset-minio-data.sh --force"
  echo "If elevated cleanup is required, run it through sudo and ownership will be restored to the calling user."
  exit 1
fi

mkdir -p "${MINIO_HOST_DATA_DIR}"
find "${MINIO_HOST_DATA_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
mkdir -p "${MINIO_HOST_DATA_DIR}/minio"
mkdir -p "${MINIO_HOST_DATA_DIR}/mlflow"
for tenant in ${MLFLOW_TENANTS}; do
  mkdir -p "${MINIO_HOST_DATA_DIR}/mlflow/${tenant}"
done
chmod "${MINIO_HOST_DATA_MODE}" "${MINIO_HOST_DATA_DIR}" "${MINIO_HOST_DATA_DIR}/minio" || true
chmod "${MINIO_HOST_DATA_MODE}" "${MINIO_HOST_DATA_DIR}/mlflow" || true
for tenant in ${MLFLOW_TENANTS}; do
  chmod "${MINIO_HOST_DATA_MODE}" "${MINIO_HOST_DATA_DIR}/mlflow/${tenant}" || true
done
restore_owner

echo "MinIO host data reset complete: ${MINIO_HOST_DATA_DIR}"
