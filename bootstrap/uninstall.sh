#!/usr/bin/env sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-aiml}"
MINIO_HOST_DATA_DIR="${MINIO_HOST_DATA_DIR:-${ROOT_DIR}/.local/minio-data}"
GITEA_HOST_DATA_DIR="${GITEA_HOST_DATA_DIR:-${ROOT_DIR}/.local/gitea-data}"

if kind get clusters | grep -x "$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "Deleting kind cluster: $CLUSTER_NAME"
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "Cluster not found: $CLUSTER_NAME"
fi

rm -rf "${GITEA_HOST_DATA_DIR}"

echo "Wiped Gitea host data at: ${GITEA_HOST_DATA_DIR}"
echo "Preserving MinIO host data at: ${MINIO_HOST_DATA_DIR}"
echo "Use ./bootstrap/reset-minio-data.sh --force for intentional local MinIO data wipe."
