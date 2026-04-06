#!/usr/bin/env sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MINIO_HOST_DATA_DIR="${MINIO_HOST_DATA_DIR:-${ROOT_DIR}/.local/minio-data}"
MINIO_HOST_DATA_MODE="${MINIO_HOST_DATA_MODE:-0777}"
MLFLOW_TENANTS="${MLFLOW_TENANTS:-ml-team-a ml-team-b}"

if [ "${1:-}" != "--force" ]; then
  echo "Refusing to delete MinIO data without explicit confirmation."
  echo "Usage: sudo ./bootstrap/reset-minio-data.sh --force"
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

echo "MinIO host data reset complete: ${MINIO_HOST_DATA_DIR}"
