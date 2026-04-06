#!/usr/bin/env sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-aiml}"
MINIO_HOST_DATA_DIR="${MINIO_HOST_DATA_DIR:-${ROOT_DIR}/.local/minio-data}"

if kind get clusters | grep -x "$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "Deleting kind cluster: $CLUSTER_NAME"
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "Cluster not found: $CLUSTER_NAME"
fi

echo "Preserving MinIO host data at: ${MINIO_HOST_DATA_DIR}"
echo "Use ./bootstrap/reset-minio-data.sh --force for intentional local MinIO data wipe."
