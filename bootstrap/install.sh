#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_KIND_CONFIG=""
CANONICAL_GITEA_ADMIN_USERNAME="gitops-admin"
CANONICAL_GITEA_REPO_NAME="ai-ml"

CLUSTER_NAME="${CLUSTER_NAME:-aiml}"
GITEA_REMOTE_NAME="${GITEA_REMOTE_NAME:-gitea}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.32.0}"
WORKER_COUNT="${WORKER_COUNT:-2}"
MINIO_HOST_DATA_DIR="${MINIO_HOST_DATA_DIR:-${ROOT_DIR}/.local/minio-data}"
MINIO_CONTAINER_DATA_DIR="${MINIO_CONTAINER_DATA_DIR:-/var/local/minio-data}"
MINIO_HOST_DATA_SUBPATH="${MINIO_HOST_DATA_SUBPATH:-minio}"
MINIO_HOST_DATA_MODE="${MINIO_HOST_DATA_MODE:-0777}"
GITEA_HOST_DATA_DIR="${GITEA_HOST_DATA_DIR:-${ROOT_DIR}/.local/gitea-data}"
GITEA_CONTAINER_DATA_DIR="${GITEA_CONTAINER_DATA_DIR:-/var/local/gitea-data}"
GITEA_HOST_DATA_SUBPATH="${GITEA_HOST_DATA_SUBPATH:-gitea}"
GITEA_HOST_DATA_MODE="${GITEA_HOST_DATA_MODE:-0777}"
GITEA_PV_NAME="${GITEA_PV_NAME:-gitea-shared-storage-pv}"
GITEA_PVC_NAME="${GITEA_PVC_NAME:-gitea-shared-storage}"
GITEA_PVC_SIZE="${GITEA_PVC_SIZE:-10Gi}"
MLFLOW_HOST_DATA_SUBPATH="${MLFLOW_HOST_DATA_SUBPATH:-mlflow}"
MLFLOW_TENANTS="${MLFLOW_TENANTS:-ml-team-a ml-team-b}"

# Docker network and MetalLB pool are explicit for reproducible local environments.
KIND_DOCKER_SUBNET="${KIND_DOCKER_SUBNET:-172.29.0.0/24}"
METALLB_RANGE="${METALLB_RANGE:-172.29.0.200-172.29.0.220}"
ARGOCD_LB_IP="${ARGOCD_LB_IP:-172.29.0.200}"
GITEA_HTTP_LB_IP="${GITEA_HTTP_LB_IP:-172.29.0.201}"
GITEA_SSH_LB_IP="${GITEA_SSH_LB_IP:-172.29.0.202}"

# Host <-> kind-control-plane port mappings.
INGRESS_HTTP_CONTAINER_PORT="${INGRESS_HTTP_CONTAINER_PORT:-80}"
INGRESS_HTTP_HOST_PORT="${INGRESS_HTTP_HOST_PORT:-8080}"
INGRESS_HTTPS_CONTAINER_PORT="${INGRESS_HTTPS_CONTAINER_PORT:-443}"
INGRESS_HTTPS_HOST_PORT="${INGRESS_HTTPS_HOST_PORT:-8443}"

# Gitea bootstrap credentials for mandatory GitOps initialization.
GITEA_ADMIN_USERNAME="${GITEA_ADMIN_USERNAME:-$CANONICAL_GITEA_ADMIN_USERNAME}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-gitops123}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-gitops-admin@example.local}"
GITEA_REPO_NAME="${GITEA_REPO_NAME:-$CANONICAL_GITEA_REPO_NAME}"

# Optional Kind node process file-descriptor tuning for log-heavy local profiles.
# Set to empty to skip.
KIND_NODE_NOFILE_LIMIT="${KIND_NODE_NOFILE_LIMIT:-1048576}"
KIND_NODE_INOTIFY_MAX_USER_INSTANCES="${KIND_NODE_INOTIFY_MAX_USER_INSTANCES:-4096}"
KIND_NODE_INOTIFY_MAX_USER_WATCHES="${KIND_NODE_INOTIFY_MAX_USER_WATCHES:-1048576}"

log() {
  printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$*"
}

cleanup() {
  if [[ -n "${TMP_KIND_CONFIG:-}" ]] && [[ -f "$TMP_KIND_CONFIG" ]]; then
    rm -f "$TMP_KIND_CONFIG"
  fi
}

require_tools() {
  "${ROOT_DIR}/bootstrap/check-prereqs.sh"
}

validate_lb_ip_config() {
  if [[ "$ARGOCD_LB_IP" == "$GITEA_HTTP_LB_IP" ]] || [[ "$ARGOCD_LB_IP" == "$GITEA_SSH_LB_IP" ]] || [[ "$GITEA_HTTP_LB_IP" == "$GITEA_SSH_LB_IP" ]]; then
    echo "Configured LoadBalancer IPs must be unique:" >&2
    echo "  ARGOCD_LB_IP=${ARGOCD_LB_IP}" >&2
    echo "  GITEA_HTTP_LB_IP=${GITEA_HTTP_LB_IP}" >&2
    echo "  GITEA_SSH_LB_IP=${GITEA_SSH_LB_IP}" >&2
    exit 1
  fi
}

validate_gitops_repo_identity() {
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

delete_existing_cluster() {
  if kind get clusters | grep -x "$CLUSTER_NAME" >/dev/null 2>&1; then
    log "Deleting existing kind cluster: $CLUSTER_NAME"
    kind delete cluster --name "$CLUSTER_NAME"
  fi
}

ensure_kind_network() {
  if docker network inspect kind >/dev/null 2>&1; then
    local existing_subnet
    local container_count
    existing_subnet="$(docker network inspect kind -f '{{(index .IPAM.Config 0).Subnet}}')"
    container_count="$(docker network inspect kind -f '{{len .Containers}}')"

    if [[ "$existing_subnet" != "$KIND_DOCKER_SUBNET" ]]; then
      if [[ "$container_count" == "0" ]]; then
        log "Recreating docker network 'kind' with subnet ${KIND_DOCKER_SUBNET} (was ${existing_subnet})"
        docker network rm kind >/dev/null
        docker network create kind --driver bridge --subnet "$KIND_DOCKER_SUBNET" >/dev/null
      else
        echo "Docker network 'kind' uses ${existing_subnet}, expected ${KIND_DOCKER_SUBNET}." >&2
        echo "Remove existing kind clusters/network or set KIND_DOCKER_SUBNET to match." >&2
        exit 1
      fi
    fi
  else
    log "Creating docker network 'kind' with subnet ${KIND_DOCKER_SUBNET}"
    docker network create kind --driver bridge --subnet "$KIND_DOCKER_SUBNET" >/dev/null
  fi
}

ensure_minio_host_data_dir() {
  local minio_data_path
  local mlflow_data_root
  local tenant
  minio_data_path="${MINIO_HOST_DATA_DIR}/${MINIO_HOST_DATA_SUBPATH}"
  mlflow_data_root="${MINIO_HOST_DATA_DIR}/${MLFLOW_HOST_DATA_SUBPATH}"

  log "Ensuring MinIO host data directory exists: ${MINIO_HOST_DATA_DIR}"
  mkdir -p "${MINIO_HOST_DATA_DIR}"
  mkdir -p "${minio_data_path}"
  mkdir -p "${mlflow_data_root}"
  chmod "${MINIO_HOST_DATA_MODE}" "${MINIO_HOST_DATA_DIR}" "${minio_data_path}" "${mlflow_data_root}" || true

  for tenant in ${MLFLOW_TENANTS}; do
    mkdir -p "${mlflow_data_root}/${tenant}"
    chmod "${MINIO_HOST_DATA_MODE}" "${mlflow_data_root}/${tenant}" || true
  done
}

ensure_gitea_host_data_dir() {
  local gitea_data_path
  gitea_data_path="${GITEA_HOST_DATA_DIR}/${GITEA_HOST_DATA_SUBPATH}"

  log "Resetting Gitea host data for install: ${GITEA_HOST_DATA_DIR}"
  rm -rf "${GITEA_HOST_DATA_DIR}"
  mkdir -p "${GITEA_HOST_DATA_DIR}"
  mkdir -p "${gitea_data_path}"
  chmod "${GITEA_HOST_DATA_MODE}" "${GITEA_HOST_DATA_DIR}" "${gitea_data_path}" || true
}

build_kind_config() {
  local tmp_config
  tmp_config="$(mktemp)"

  {
    cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
networking:
  disableDefaultCNI: false
  kubeProxyMode: "iptables"
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: ${INGRESS_HTTP_CONTAINER_PORT}
    hostPort: ${INGRESS_HTTP_HOST_PORT}
    protocol: TCP
  - containerPort: ${INGRESS_HTTPS_CONTAINER_PORT}
    hostPort: ${INGRESS_HTTPS_HOST_PORT}
    protocol: TCP
  extraMounts:
  - hostPath: ${MINIO_HOST_DATA_DIR}
    containerPath: ${MINIO_CONTAINER_DATA_DIR}
  - hostPath: ${GITEA_HOST_DATA_DIR}
    containerPath: ${GITEA_CONTAINER_DATA_DIR}
EOF
    for _ in $(seq 1 "$WORKER_COUNT"); do
      cat <<EOF
- role: worker
  extraMounts:
  - hostPath: ${MINIO_HOST_DATA_DIR}
    containerPath: ${MINIO_CONTAINER_DATA_DIR}
  - hostPath: ${GITEA_HOST_DATA_DIR}
    containerPath: ${GITEA_CONTAINER_DATA_DIR}
EOF
    done
  } >"$tmp_config"

  echo "$tmp_config"
}

create_cluster() {
  local config="$1"
  log "Creating kind cluster: $CLUSTER_NAME"
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --config "$config" --wait 180s
  kind export kubeconfig --name "$CLUSTER_NAME"
  kubectl cluster-info
}

tune_kind_node_nofile() {
  local limit="$1"
  local node
  local containerd_pid
  local kubelet_pid

  if [[ -z "$limit" ]]; then
    log "Skipping Kind node nofile tuning (KIND_NODE_NOFILE_LIMIT is empty)"
    return
  fi

  # Keep this best-effort; cluster bootstrap should still proceed even if a host/runtime blocks tuning.
  log "Tuning Kind node nofile soft/hard limits to ${limit} (best-effort)"
  for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    echo "- node: ${node}"
    docker exec "$node" sh -lc '
      set -eu
      limit="'"$limit"'"
      if ! command -v prlimit >/dev/null 2>&1; then
        echo "  prlimit not found inside node container; skipping"
        exit 0
      fi

      containerd_pid="$(pidof containerd | awk "{print \$1}" || true)"
      kubelet_pid="$(pidof kubelet | awk "{print \$1}" || true)"

      if [ -n "${containerd_pid}" ]; then
        prlimit --pid "${containerd_pid}" --nofile="${limit}:${limit}" || true
        awk "/Max open files/ {print \"  containerd \" \$0}" /proc/"${containerd_pid}"/limits || true
      else
        echo "  containerd pid not found"
      fi

      if [ -n "${kubelet_pid}" ]; then
        prlimit --pid "${kubelet_pid}" --nofile="${limit}:${limit}" || true
        awk "/Max open files/ {print \"  kubelet    \" \$0}" /proc/"${kubelet_pid}"/limits || true
      else
        echo "  kubelet pid not found"
      fi
    ' || true
  done
}

tune_kind_node_kernel_limits() {
  local node
  local max_instances="$1"
  local max_watches="$2"

  if [[ -z "$max_instances" || -z "$max_watches" ]]; then
    log "Skipping Kind node inotify tuning (KIND_NODE_INOTIFY_* is empty)"
    return
  fi

  log "Tuning Kind node inotify limits (instances=${max_instances}, watches=${max_watches})"
  for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    echo "- node: ${node}"
    docker exec "$node" sh -lc '
      set -eu
      max_instances="'"$max_instances"'"
      max_watches="'"$max_watches"'"
      sysctl -w fs.inotify.max_user_instances="${max_instances}" || true
      sysctl -w fs.inotify.max_user_watches="${max_watches}" || true
      sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches || true
    ' || true
  done
}

install_metallb() {
  log "Installing MetalLB"
  kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml"
  kubectl -n metallb-system wait deploy/controller --for=condition=Available=True --timeout=180s

  log "Configuring MetalLB IPAddressPool: $METALLB_RANGE"
  cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - kind-pool
EOF
}

install_argocd() {
  log "Installing Argo CD"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  # Server-side apply avoids oversized last-applied annotations on large CRDs.
  kubectl apply --server-side -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.6/manifests/install.yaml"

  # Wait for the deployment object to exist before waiting on availability.
  local i
  for i in $(seq 1 60); do
    if kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if ! kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
    echo "Argo CD deployment 'argocd-server' was not created in namespace 'argocd'." >&2
    kubectl get deploy -A | grep argocd || true
    exit 1
  fi

  kubectl -n argocd wait deploy/argocd-server --for=condition=Available=True --timeout=300s
  kubectl -n argocd patch svc argocd-server --type merge -p "{\"spec\":{\"type\":\"LoadBalancer\",\"loadBalancerIP\":\"${ARGOCD_LB_IP}\"}}"
}

install_gitea() {
  local gitea_pv_path
  local waited
  local pvc_phase

  log "Installing Gitea"
  helm repo add gitea-charts https://dl.gitea.io/charts/ >/dev/null
  helm repo update >/dev/null

  kubectl create namespace gitea --dry-run=client -o yaml | kubectl apply -f -

  gitea_pv_path="${GITEA_CONTAINER_DATA_DIR}/${GITEA_HOST_DATA_SUBPATH}"
  log "Reconciling Gitea host-backed persistence at ${GITEA_HOST_DATA_DIR}/${GITEA_HOST_DATA_SUBPATH}"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${GITEA_PV_NAME}
spec:
  capacity:
    storage: ${GITEA_PVC_SIZE}
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: ${gitea_pv_path}
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${GITEA_PVC_NAME}
  namespace: gitea
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: ""
  volumeName: ${GITEA_PV_NAME}
  resources:
    requests:
      storage: ${GITEA_PVC_SIZE}
EOF

  waited=0
  pvc_phase=""
  while [[ "$waited" -lt 60 ]]; do
    pvc_phase="$(kubectl -n gitea get pvc "${GITEA_PVC_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$pvc_phase" == "Bound" ]]; then
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  if [[ "$pvc_phase" != "Bound" ]]; then
    echo "Timed out waiting for Gitea PVC ${GITEA_PVC_NAME} to bind." >&2
    kubectl get pv "${GITEA_PV_NAME}" >&2 || true
    kubectl -n gitea get pvc "${GITEA_PVC_NAME}" >&2 || true
    exit 1
  fi

  helm upgrade --install gitea gitea-charts/gitea \
    --namespace gitea \
    --set persistence.enabled=true \
    --set persistence.create=false \
    --set-string persistence.claimName="${GITEA_PVC_NAME}" \
    --set redis-cluster.enabled=false \
    --set postgresql-ha.enabled=false \
    --set-string gitea.admin.username="${GITEA_ADMIN_USERNAME}" \
    --set-string gitea.admin.password="${GITEA_ADMIN_PASSWORD}" \
    --set-string gitea.admin.email="${GITEA_ADMIN_EMAIL}" \
    --set gitea.config.database.DB_TYPE=sqlite3 \
    --set gitea.config.security.INSTALL_LOCK=true \
    --set service.http.type=LoadBalancer \
    --set service.ssh.type=LoadBalancer \
    --set service.http.loadBalancerIP="${GITEA_HTTP_LB_IP}" \
    --set service.ssh.loadBalancerIP="${GITEA_SSH_LB_IP}"

  # Enforce fixed IPs regardless of chart defaults/template changes.
  kubectl -n gitea patch svc gitea-http --type merge -p "{\"spec\":{\"type\":\"LoadBalancer\",\"loadBalancerIP\":\"${GITEA_HTTP_LB_IP}\"}}"
  kubectl -n gitea patch svc gitea-ssh --type merge -p "{\"spec\":{\"type\":\"LoadBalancer\",\"loadBalancerIP\":\"${GITEA_SSH_LB_IP}\"}}"

  kubectl -n gitea wait deploy/gitea --for=condition=Available=True --timeout=300s
}

initialize_gitops() {
  log "Initializing mandatory GitOps wiring"
  GITEA_ADMIN_USERNAME="$GITEA_ADMIN_USERNAME" \
  GITEA_ADMIN_PASSWORD="$GITEA_ADMIN_PASSWORD" \
  GITEA_ADMIN_EMAIL="$GITEA_ADMIN_EMAIL" \
  GITEA_REPO_NAME="$GITEA_REPO_NAME" \
    "${ROOT_DIR}/bootstrap/gitops-init.sh"
}

print_git_remote_handoff() {
  local branch
  local upstream
  local gitea_remote_url
  local origin_remote_url

  branch="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
  upstream="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  gitea_remote_url="$(git -C "$ROOT_DIR" remote get-url "$GITEA_REMOTE_NAME" 2>/dev/null || true)"
  origin_remote_url="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"

  log "Local git remote handoff"
  echo "Current branch: ${branch}"
  echo "Current branch upstream: ${upstream:-<none>}"
  echo "In-cluster GitOps remote (${GITEA_REMOTE_NAME}): ${gitea_remote_url:-<missing>}"
  if [[ -n "$origin_remote_url" ]]; then
    echo "Original clone remote preserved (origin): ${origin_remote_url}"
    echo "Default git pull/push on branch '${branch}' now use in-cluster Gitea."
    echo "Push back to your original clone source explicitly when needed:"
    echo "  git push origin ${branch}"
  else
    echo "No origin remote was detected in the local clone."
  fi
}

print_endpoints() {
  local argocd_ip
  local gitea_http_ip
  local gitea_ssh_ip

  argocd_ip="$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  gitea_http_ip="$(kubectl -n gitea get svc gitea-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  gitea_ssh_ip="$(kubectl -n gitea get svc gitea-ssh -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

  log "Service endpoints"
  echo "Kubernetes context: $(kubectl config current-context)"
  kubectl get svc -n argocd argocd-server
  kubectl get svc -n gitea gitea-http gitea-ssh
  echo
  echo "Configured static LoadBalancer IPs"
  echo "- Argo CD:   ${ARGOCD_LB_IP}"
  echo "- Gitea HTTP:${GITEA_HTTP_LB_IP}"
  echo "- Gitea SSH: ${GITEA_SSH_LB_IP}"
  echo
  echo "Access URLs"
  echo "- Argo CD UI: https://${argocd_ip}"
  echo "- Gitea UI:   http://${gitea_http_ip}:3000"
  echo "- Gitea SSH:  ssh://git@${gitea_ssh_ip}:22/${GITEA_ADMIN_USERNAME}/${GITEA_REPO_NAME}.git"
  echo
  echo "Argo CD admin password:"
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  echo
}

main() {
  trap cleanup EXIT
  require_tools
  validate_lb_ip_config
  validate_gitops_repo_identity
  delete_existing_cluster
  ensure_kind_network
  ensure_minio_host_data_dir
  ensure_gitea_host_data_dir
  TMP_KIND_CONFIG="$(build_kind_config)"
  create_cluster "$TMP_KIND_CONFIG"
  tune_kind_node_nofile "$KIND_NODE_NOFILE_LIMIT"
  tune_kind_node_kernel_limits "$KIND_NODE_INOTIFY_MAX_USER_INSTANCES" "$KIND_NODE_INOTIFY_MAX_USER_WATCHES"
  install_metallb
  install_argocd
  install_gitea
  initialize_gitops
  print_git_remote_handoff
  print_endpoints
  log "Bootstrap complete."
}

main "$@"
