#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLOR_ENABLED=0
C_RESET=""
C_BOLD=""
C_DIM=""
C_RED=""
C_GREEN=""
C_YELLOW=""
C_BLUE=""
C_MAGENTA=""
C_CYAN=""

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required command: $tool" >&2
    exit 1
  fi
}

init_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    COLOR_ENABLED=1
    C_RESET="$(printf '\033[0m')"
    C_BOLD="$(printf '\033[1m')"
    C_DIM="$(printf '\033[2m')"
    C_RED="$(printf '\033[31m')"
    C_GREEN="$(printf '\033[32m')"
    C_YELLOW="$(printf '\033[33m')"
    C_BLUE="$(printf '\033[34m')"
    C_MAGENTA="$(printf '\033[35m')"
    C_CYAN="$(printf '\033[36m')"
  fi
}

paint() {
  local style="$1"
  shift
  if [[ "$COLOR_ENABLED" -eq 1 ]]; then
    printf "%b%s%b" "$style" "$*" "$C_RESET"
  else
    printf "%s" "$*"
  fi
}

print_section() {
  printf "\n%s\n" "$(paint "${C_BOLD}${C_BLUE}" "## $1")"
}

render_table() {
  local tsv="$1"
  if command -v column >/dev/null 2>&1; then
    printf "%s\n" "$tsv" | column -t -s $'\t'
  else
    printf "%s\n" "$tsv" | sed $'s/\t/  /g'
  fi
}

read_install_default() {
  local var="$1"
  [[ -f "${ROOT_DIR}/bootstrap/install.sh" ]] || return 0
  sed -n "s/^${var}=\"\${${var}:-\\([^}]*\\)}\"$/\\1/p" "${ROOT_DIR}/bootstrap/install.sh" | head -n 1
}

read_minio_lb_ip_from_repo() {
  [[ -f "${ROOT_DIR}/infra/minio/manifests/service.yaml" ]] || return 0
  sed -n 's/^[[:space:]]*loadBalancerIP:[[:space:]]*//p' "${ROOT_DIR}/infra/minio/manifests/service.yaml" | head -n 1
}

read_monitoring_grafana_lb_ip_from_repo() {
  [[ -f "${ROOT_DIR}/infra/monitoring/values/kube-prometheus-stack-values.yaml" ]] || return 0
  sed -n 's/^[[:space:]]*loadBalancerIP:[[:space:]]*//p' "${ROOT_DIR}/infra/monitoring/values/kube-prometheus-stack-values.yaml" | head -n 1
}

read_istio_ingress_lb_ip_from_repo() {
  [[ -f "${ROOT_DIR}/infra/istio/application-ingressgateway.yaml" ]] || return 0
  awk '
    $0 ~ /^[[:space:]]*- name:[[:space:]]*service\.loadBalancerIP[[:space:]]*$/ {capture=1; next}
    capture && $0 ~ /^[[:space:]]*value:[[:space:]]*/ {
      sub(/^[[:space:]]*value:[[:space:]]*/, "", $0)
      print $0
      exit
    }
  ' "${ROOT_DIR}/infra/istio/application-ingressgateway.yaml"
}

read_repo_knative_domains() {
  [[ -f "${ROOT_DIR}/infra/knative/manifests/serving-core/config-domain-patch.yaml" ]] || return 0
  awk '
    /^data:[[:space:]]*$/ {in_data=1; next}
    in_data && /^[[:space:]]*[A-Za-z0-9.-]+:[[:space:]]*/ {
      key=$1
      sub(/:$/, "", key)
      print key
    }
  ' "${ROOT_DIR}/infra/knative/manifests/serving-core/config-domain-patch.yaml"
}

service_exists() {
  local namespace="$1"
  local service="$2"
  kubectl -n "$namespace" get svc "$service" >/dev/null 2>&1
}

get_service_type() {
  local namespace="$1"
  local service="$2"
  if ! service_exists "$namespace" "$service"; then
    echo "<missing>"
    return
  fi

  kubectl -n "$namespace" get svc "$service" -o jsonpath='{.spec.type}' 2>/dev/null || true
}

get_service_external_address() {
  local namespace="$1"
  local service="$2"
  local ip
  local host

  if ! service_exists "$namespace" "$service"; then
    echo "<missing>"
    return
  fi

  ip="$(kubectl -n "$namespace" get svc "$service" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  host="$(kubectl -n "$namespace" get svc "$service" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

  if [[ -n "$ip" ]]; then
    echo "$ip"
    return
  fi
  if [[ -n "$host" ]]; then
    echo "$host"
    return
  fi

  echo "<pending>"
}

get_service_ports() {
  local namespace="$1"
  local service="$2"
  local ports

  if ! service_exists "$namespace" "$service"; then
    echo "<missing>"
    return
  fi

  ports="$(kubectl -n "$namespace" get svc "$service" -o jsonpath='{range .spec.ports[*]}{.name}{":"}{.port}{"/"}{.protocol}{" "}{end}' 2>/dev/null || true)"
  ports="${ports%" "}"
  if [[ -n "$ports" ]]; then
    echo "$ports"
  else
    echo "<none>"
  fi
}

format_url() {
  local scheme="$1"
  local address="$2"
  local port="${3:-}"
  local suffix="${4:-}"

  if [[ -z "$address" || "$address" == "<missing>" || "$address" == "<pending>" ]]; then
    echo "<unavailable>"
    return
  fi

  if [[ -n "$port" ]]; then
    echo "${scheme}://${address}:${port}${suffix}"
  else
    echo "${scheme}://${address}${suffix}"
  fi
}

normalize_hosts() {
  local raw
  local host

  while IFS= read -r raw; do
    raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
    [[ -z "$raw" ]] && continue

    host="${raw#http://}"
    host="${host#https://}"
    host="${host%%/*}"
    host="${host%%:*}"

    [[ -z "$host" ]] && continue
    [[ "$host" != *.* ]] && continue
    [[ "$host" == "*" ]] && continue
    [[ "$host" == _* ]] && continue
    [[ "$host" == *".svc.cluster.local" ]] && continue

    printf '%s\n' "$host"
  done
}

collect_virtualservice_hosts_from_file() {
  local file="$1"
  awk '
    /^[[:space:]]*hosts:[[:space:]]*$/ {in_hosts=1; next}
    in_hosts && /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*$/ {in_hosts=0}
    in_hosts && /^[[:space:]]*-[[:space:]]*/ {
      host=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", host)
      gsub(/["[:space:]]/, "", host)
      print host
      next
    }
    in_hosts && /^[^[:space:]]/ {in_hosts=0}
  ' "$file"
}

collect_repo_mlflow_hosts() {
  local file

  for file in "${ROOT_DIR}"/teams/*/mlflow/virtualservice-mlflow.yaml; do
    [[ -f "$file" ]] || continue
    collect_virtualservice_hosts_from_file "$file"
  done
}

collect_repo_grafana_hosts() {
  local file

  for file in "${ROOT_DIR}"/infra/monitoring/manifests/virtualservice-*.yaml; do
    [[ -f "$file" ]] || continue
    collect_virtualservice_hosts_from_file "$file"
  done
}

collect_repo_virtualservice_hosts() {
  collect_repo_mlflow_hosts
  collect_repo_grafana_hosts
}

collect_cluster_virtualservice_hosts() {
  if kubectl get virtualservice -A >/dev/null 2>&1; then
    kubectl get virtualservice -A -o jsonpath='{range .items[*]}{range .spec.hosts[*]}{.}{"\n"}{end}{end}' 2>/dev/null || true
  fi
}

collect_cluster_status_urls() {
  local resource="$1"
  if kubectl get "$resource" -A >/dev/null 2>&1; then
    kubectl get "$resource" -A -o jsonpath='{range .items[*]}{.status.url}{"\n"}{end}' 2>/dev/null || true
  fi
}

collect_cluster_knative_domains() {
  kubectl -n knative-serving get configmap config-domain -o go-template='{{range $k, $v := .data}}{{printf "%s\n" $k}}{{end}}' 2>/dev/null || true
}

print_named_service_row() {
  local namespace="$1"
  local service="$2"
  local configured="$3"
  local type
  local live_addr
  local ports
  local readiness

  type="$(get_service_type "$namespace" "$service")"
  live_addr="$(get_service_external_address "$namespace" "$service")"
  ports="$(get_service_ports "$namespace" "$service")"
  readiness="$(service_readiness "$configured" "$live_addr")"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$namespace" \
    "$service" \
    "$type" \
    "${configured:-<n/a>}" \
    "$live_addr" \
    "$readiness" \
    "$ports"
}

print_app_health_summary() {
  local app_rows="$1"
  local total=0
  local healthy=0
  local synced=0
  local not_healthy=0
  local out_of_sync=0
  local unknown=0

  if [[ -z "$app_rows" ]]; then
    return
  fi

  while IFS='|' read -r name sync health revision; do
    [[ -z "${name:-}" ]] && continue
    total=$((total + 1))
    [[ "$sync" == "Synced" ]] && synced=$((synced + 1))
    [[ "$health" == "Healthy" ]] && healthy=$((healthy + 1))
    [[ "$sync" != "Synced" ]] && out_of_sync=$((out_of_sync + 1))
    [[ "$health" != "Healthy" ]] && not_healthy=$((not_healthy + 1))
    [[ "$health" == "Unknown" ]] && unknown=$((unknown + 1))
  done <<< "$app_rows"

  echo "Applications: ${total} total | $(paint "${C_GREEN}" "${synced} synced") | $(paint "${C_GREEN}" "${healthy} healthy")"
  if ((out_of_sync > 0 || not_healthy > 0)); then
    echo "$(paint "${C_YELLOW}" "Attention: ${out_of_sync} out-of-sync, ${not_healthy} not-healthy (${unknown} unknown).")"
  fi
}

service_readiness() {
  local configured="$1"
  local live="$2"

  if [[ "$live" == "<missing>" ]]; then
    echo "$(paint "${C_RED}" "MISSING")"
    return
  fi
  if [[ "$live" == "<pending>" || -z "$live" ]]; then
    echo "$(paint "${C_YELLOW}" "PENDING")"
    return
  fi
  if [[ -n "$configured" && "$configured" != "<n/a>" && "$configured" == "$live" ]]; then
    echo "$(paint "${C_GREEN}" "OK")"
    return
  fi
  if [[ -n "$configured" && "$configured" != "<n/a>" && "$configured" != "$live" ]]; then
    echo "$(paint "${C_YELLOW}" "DRIFT")"
    return
  fi
  echo "$(paint "${C_GREEN}" "OK")"
}

colorize_status_table() {
  local table="$1"
  local line

  if [[ "$COLOR_ENABLED" -ne 1 ]]; then
    printf "%s\n" "$table"
    return
  fi

  while IFS= read -r line; do
    line="${line//Synced/$(paint "${C_GREEN}" "Synced")}"
    line="${line//OutOfSync/$(paint "${C_YELLOW}" "OutOfSync")}"
    line="${line//Healthy/$(paint "${C_GREEN}" "Healthy")}"
    line="${line//Degraded/$(paint "${C_RED}" "Degraded")}"
    line="${line//Progressing/$(paint "${C_YELLOW}" "Progressing")}"
    line="${line//Unknown/$(paint "${C_YELLOW}" "Unknown")}"
    line="${line//MISSING/$(paint "${C_RED}" "MISSING")}"
    line="${line//PENDING/$(paint "${C_YELLOW}" "PENDING")}"
    line="${line//DRIFT/$(paint "${C_YELLOW}" "DRIFT")}"
    line="${line//OK/$(paint "${C_GREEN}" "OK")}"
    printf "%s\n" "$line"
  done <<< "$table"
}

decode_base64() {
  local value="$1"
  if decoded="$(printf '%s' "$value" | base64 -d 2>/dev/null)"; then
    printf '%s' "$decoded"
    return 0
  fi
  if decoded="$(printf '%s' "$value" | base64 --decode 2>/dev/null)"; then
    printf '%s' "$decoded"
    return 0
  fi
  return 1
}

get_argocd_admin_password() {
  local encoded
  local decoded
  encoded="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null || true)"
  if [[ -z "$encoded" ]]; then
    echo "<unavailable>"
    return
  fi
  decoded="$(decode_base64 "$encoded" || true)"
  if [[ -z "$decoded" ]]; then
    echo "<unavailable>"
  else
    echo "$decoded"
  fi
}

get_grafana_admin_password() {
  local encoded
  local decoded
  encoded="$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null || true)"
  if [[ -z "$encoded" ]]; then
    echo "<unavailable>"
    return
  fi
  decoded="$(decode_base64 "$encoded" || true)"
  if [[ -z "$decoded" ]]; then
    echo "<unavailable>"
  else
    echo "$decoded"
  fi
}

main() {
  require_tool kubectl
  init_colors

  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "kubectl cannot reach a cluster. Run this after bootstrap and health checks pass." >&2
    exit 1
  fi

  local context
  local api_server
  local now
  local configured_metallb_range
  local configured_argocd_ip
  local configured_gitea_http_ip
  local configured_gitea_ssh_ip
  local configured_istio_ingress_ip
  local configured_minio_ip
  local configured_grafana_ip
  local configured_gitea_user
  local configured_gitea_password
  local argocd_admin_password
  local grafana_admin_password
  local argocd_addr
  local grafana_addr
  local gitea_http_addr
  local gitea_ssh_addr
  local ingress_addr
  local minio_addr
  local ingress_addr_for_hosts
  local argo_app_tsv_rows
  local lb_extra_rows
  local vs_tsv_rows
  local isvc_tsv_rows
  local ksvc_tsv_rows
  local host
  local host_lines=""
  local common_ip
  local ingress_host_count=0
  local extra_lb_count=0
  local core_lb_tsv
  local core_lb_table
  local argo_tsv
  local argo_table
  local direct_access_tsv
  local direct_access_table
  local lb_extra_tsv
  local lb_extra_table
  local vs_tsv
  local vs_table
  local isvc_tsv
  local isvc_table
  local ksvc_tsv
  local ksvc_table

  local -a repo_mlflow_hosts=()
  local -a repo_grafana_hosts=()
  local -a repo_knative_domains=()
  local -a live_knative_domains=()
  local -a ingress_hosts=()
  local -a core_lb_keys=(
    "argocd/argocd-server"
    "gitea/gitea-http"
    "gitea/gitea-ssh"
    "istio-system/istio-ingressgateway"
    "minio/minio"
    "monitoring/kube-prometheus-stack-grafana"
  )

  now="$(date +'%Y-%m-%d %H:%M:%S %Z')"
  context="$(kubectl config current-context 2>/dev/null || true)"
  api_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"

  configured_metallb_range="$(read_install_default METALLB_RANGE)"
  configured_argocd_ip="$(read_install_default ARGOCD_LB_IP)"
  configured_gitea_http_ip="$(read_install_default GITEA_HTTP_LB_IP)"
  configured_gitea_ssh_ip="$(read_install_default GITEA_SSH_LB_IP)"
  configured_gitea_user="$(read_install_default GITEA_ADMIN_USERNAME)"
  configured_gitea_password="$(read_install_default GITEA_ADMIN_PASSWORD)"
  argocd_admin_password="$(get_argocd_admin_password)"
  grafana_admin_password="$(get_grafana_admin_password)"
  configured_istio_ingress_ip="$(read_istio_ingress_lb_ip_from_repo)"
  configured_minio_ip="$(read_minio_lb_ip_from_repo)"
  configured_grafana_ip="$(read_monitoring_grafana_lb_ip_from_repo)"

  argocd_addr="$(get_service_external_address argocd argocd-server)"
  grafana_addr="$(get_service_external_address monitoring kube-prometheus-stack-grafana)"
  gitea_http_addr="$(get_service_external_address gitea gitea-http)"
  gitea_ssh_addr="$(get_service_external_address gitea gitea-ssh)"
  ingress_addr="$(get_service_external_address istio-system istio-ingressgateway)"
  minio_addr="$(get_service_external_address minio minio)"

  mapfile -t repo_mlflow_hosts < <(collect_repo_mlflow_hosts | normalize_hosts | sort -u)
  mapfile -t repo_grafana_hosts < <(collect_repo_grafana_hosts | normalize_hosts | sort -u)
  mapfile -t repo_knative_domains < <(read_repo_knative_domains | normalize_hosts | sort -u)
  mapfile -t live_knative_domains < <(collect_cluster_knative_domains | normalize_hosts | sort -u)
  mapfile -t ingress_hosts < <(
    {
      collect_repo_virtualservice_hosts
      collect_cluster_virtualservice_hosts
      collect_cluster_status_urls inferenceservice
      collect_cluster_status_urls ksvc
    } | normalize_hosts | sort -u
  )

  if [[ "$ingress_addr" == "<missing>" || "$ingress_addr" == "<pending>" || -z "$ingress_addr" ]]; then
    ingress_addr_for_hosts="$configured_istio_ingress_ip"
  else
    ingress_addr_for_hosts="$ingress_addr"
  fi

  echo "$(paint "${C_BOLD}${C_MAGENTA}" "ai-ml endpoint discovery report")"
  echo "$(paint "${C_DIM}" "Generated: ${now}")"
  echo "Kubernetes context: $(paint "${C_CYAN}" "${context:-<unknown>}")"
  echo "Kubernetes API server: $(paint "${C_CYAN}" "${api_server:-<unknown>}")"

  print_section "Repo Config Snapshot"
  echo "MetalLB range: $(paint "${C_CYAN}" "${configured_metallb_range:-<unknown>}")"
  echo "Configured static IPs:"
  echo "- argocd/argocd-server: ${configured_argocd_ip:-<unknown>}"
  echo "- gitea/gitea-http: ${configured_gitea_http_ip:-<unknown>}"
  echo "- gitea/gitea-ssh: ${configured_gitea_ssh_ip:-<unknown>}"
  echo "- istio-system/istio-ingressgateway: ${configured_istio_ingress_ip:-<unknown>}"
  echo "- minio/minio: ${configured_minio_ip:-<unknown>}"
  echo "- monitoring/kube-prometheus-stack-grafana: ${configured_grafana_ip:-<unknown>}"

  if ((${#repo_knative_domains[@]} > 0)); then
    echo "Configured Knative domains (repo):"
    printf '%s\n' "${repo_knative_domains[@]}" | sed 's/^/- /'
  else
    echo "Configured Knative domains (repo): <none found>"
  fi

  if ((${#repo_mlflow_hosts[@]} > 0)); then
    echo "Configured MLflow hosts (repo):"
    printf '%s\n' "${repo_mlflow_hosts[@]}" | sed 's/^/- /'
  else
    echo "Configured MLflow hosts (repo): <none found>"
  fi

  if ((${#repo_grafana_hosts[@]} > 0)); then
    echo "Configured Grafana hosts (repo):"
    printf '%s\n' "${repo_grafana_hosts[@]}" | sed 's/^/- /'
  else
    echo "Configured Grafana hosts (repo): <none found>"
  fi

  print_section "Core LoadBalancer Services"
  core_lb_tsv=$'NAMESPACE\tSERVICE\tTYPE\tCONFIGURED_IP\tLIVE_ADDR\tREADY\tPORTS'
  core_lb_tsv+=$'\n'"$(print_named_service_row argocd argocd-server "$configured_argocd_ip")"
  core_lb_tsv+=$'\n'"$(print_named_service_row gitea gitea-http "$configured_gitea_http_ip")"
  core_lb_tsv+=$'\n'"$(print_named_service_row gitea gitea-ssh "$configured_gitea_ssh_ip")"
  core_lb_tsv+=$'\n'"$(print_named_service_row istio-system istio-ingressgateway "$configured_istio_ingress_ip")"
  core_lb_tsv+=$'\n'"$(print_named_service_row minio minio "$configured_minio_ip")"
  core_lb_tsv+=$'\n'"$(print_named_service_row monitoring kube-prometheus-stack-grafana "$configured_grafana_ip")"
  core_lb_table="$(render_table "$core_lb_tsv")"
  colorize_status_table "$core_lb_table"

  lb_extra_rows="$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.type}{"\t"}{.status.loadBalancer.ingress[0].ip}{"\t"}{.status.loadBalancer.ingress[0].hostname}{"\t"}{range $i,$p := .spec.ports}{if $i},{end}{$p.port}{end}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "$lb_extra_rows" ]]; then
    lb_extra_rows="$(
      while IFS=$'\t' read -r ns name type ext_ip ext_host ports; do
        [[ -z "$ns" ]] && continue
        local_key="${ns}/${name}"
        is_core=0
        for core_key in "${core_lb_keys[@]}"; do
          if [[ "$local_key" == "$core_key" ]]; then
            is_core=1
            break
          fi
        done
        if [[ "$is_core" -eq 0 ]]; then
          printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$ns" "$name" "$type" "${ext_ip:-<none>}" "${ext_host:-<none>}" "${ports:-<none>}"
        fi
      done <<< "$lb_extra_rows"
    )"
  fi

  print_section "Direct Access URLs And Login Info"
  direct_access_tsv=$'TARGET\tURL\tLOGIN_OR_NOTES'
  direct_access_tsv+=$'\n'"Argo CD UI"$'\t'"$(format_url https "$argocd_addr")"$'\t'"admin / ${argocd_admin_password}"
  direct_access_tsv+=$'\n'"Gitea UI"$'\t'"$(format_url http "$gitea_http_addr" 3000)"$'\t'"${configured_gitea_user:-gitops-admin} / ${configured_gitea_password:-<unknown>}"
  if [[ "$gitea_ssh_addr" == "<missing>" || "$gitea_ssh_addr" == "<pending>" || -z "$gitea_ssh_addr" ]]; then
    direct_access_tsv+=$'\n'"Gitea SSH"$'\t'"<unavailable>"$'\t'"Use your local SSH key"
  else
    direct_access_tsv+=$'\n'"Gitea SSH"$'\t'"ssh://git@${gitea_ssh_addr}:22/${configured_gitea_user:-gitops-admin}/<repo>.git"$'\t'"Use your local SSH key"
  fi
  direct_access_tsv+=$'\n'"MinIO API"$'\t'"$(format_url http "$minio_addr" 9000)"$'\t'"minioadmin / minioadmin123"
  direct_access_tsv+=$'\n'"MinIO Console"$'\t'"$(format_url http "$minio_addr" 9001)"$'\t'"minioadmin / minioadmin123"
  direct_access_tsv+=$'\n'"Grafana UI (LB)"$'\t'"$(format_url http "$grafana_addr")"$'\t'"admin / ${grafana_admin_password}"
  if ((${#repo_grafana_hosts[@]} > 0)); then
    for host in "${repo_grafana_hosts[@]}"; do
      direct_access_tsv+=$'\n'"Grafana UI (Host)"$'\t'"http://${host}"$'\t'"admin / ${grafana_admin_password}"
    done
  fi
  if ((${#repo_mlflow_hosts[@]} > 0)); then
    for host in "${repo_mlflow_hosts[@]}"; do
      direct_access_tsv+=$'\n'"MLflow UI"$'\t'"http://${host}"$'\t'"Team-scoped MLflow endpoint"
    done
  fi
  if [[ "$ingress_addr" != "<missing>" && "$ingress_addr" != "<pending>" && -n "$ingress_addr" ]]; then
    direct_access_tsv+=$'\n'"Model Ingress Base"$'\t'"http://${ingress_addr}"$'\t'"Use Host header for model routes"
  fi
  direct_access_table="$(render_table "$direct_access_tsv")"
  printf "%s\n" "$direct_access_table"

  if [[ -n "$lb_extra_rows" ]]; then
    while IFS= read -r _; do
      [[ -n "${_:-}" ]] && extra_lb_count=$((extra_lb_count + 1))
    done <<< "$lb_extra_rows"
    if ((extra_lb_count > 0)); then
      print_section "Additional LoadBalancer Services"
      lb_extra_tsv=$'NAMESPACE\tNAME\tTYPE\tEXTERNAL_IP\tEXTERNAL_HOST\tPORTS'
      lb_extra_tsv+=$'\n'"$lb_extra_rows"
      lb_extra_table="$(render_table "$lb_extra_tsv")"
      printf "%s\n" "$lb_extra_table"
    fi
  fi

  argo_app_tsv_rows="$(kubectl -n argocd get applications.argoproj.io -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\t"}{.status.sync.revision}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "$argo_app_tsv_rows" ]]; then
    print_section "Argo CD Summary"
    print_app_health_summary "$(printf '%s\n' "$argo_app_tsv_rows" | awk -F'\t' '{print $1 "|" $2 "|" $3 "|" $4}')"

    print_section "Argo CD Application Health"
    argo_tsv=$'NAME\tSYNC\tHEALTH\tREVISION'
    argo_tsv+=$'\n'"$(printf '%s\n' "$argo_app_tsv_rows" | sort -t$'\t' -k1,1)"
    argo_table="$(render_table "$argo_tsv")"
    colorize_status_table "$argo_table"
  fi

  vs_tsv_rows="$(kubectl get virtualservice -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range $i, $h := .spec.hosts}{if $i},{end}{$h}{end}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "$vs_tsv_rows" ]]; then
    print_section "VirtualService Hosts"
    vs_tsv=$'NAMESPACE\tNAME\tHOSTS'
    vs_tsv+=$'\n'"$vs_tsv_rows"
    vs_table="$(render_table "$vs_tsv")"
    printf "%s\n" "$vs_table"
  fi

  isvc_tsv_rows="$(kubectl get inferenceservice -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.url}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "$isvc_tsv_rows" ]]; then
    print_section "InferenceService URLs"
    isvc_tsv=$'NAMESPACE\tNAME\tURL'
    isvc_tsv+=$'\n'"$isvc_tsv_rows"
    isvc_table="$(render_table "$isvc_tsv")"
    printf "%s\n" "$isvc_table"
  fi

  ksvc_tsv_rows="$(kubectl get ksvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.url}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "$ksvc_tsv_rows" ]]; then
    print_section "Knative Service URLs"
    ksvc_tsv=$'NAMESPACE\tNAME\tURL'
    ksvc_tsv+=$'\n'"$ksvc_tsv_rows"
    ksvc_table="$(render_table "$ksvc_tsv")"
    printf "%s\n" "$ksvc_table"
  fi

  if ((${#live_knative_domains[@]} > 0)); then
    print_section "Live Knative Domains"
    printf "%s\n" "${live_knative_domains[*]}"
  fi

  print_section "/etc/hosts Convenience"
  if [[ -z "$ingress_addr_for_hosts" || "$ingress_addr_for_hosts" == "<missing>" || "$ingress_addr_for_hosts" == "<pending>" ]]; then
    echo "Ingress gateway address is not available yet; cannot render a host-file mapping line."
  elif ((${#ingress_hosts[@]} == 0)); then
    echo "No ingress hostnames were discovered from repo or live cluster resources."
  else
    echo "$(paint "${C_BOLD}" "Add these lines to /etc/hosts for local DNS convenience:")"
    for host in "${ingress_hosts[@]}"; do
      [[ -z "$host" ]] && continue
      echo "${ingress_addr_for_hosts} ${host}"
      host_lines+="${ingress_addr_for_hosts} ${host}"$'\n'
      ingress_host_count=$((ingress_host_count + 1))
    done
    echo
    echo "$(paint "${C_BOLD}" "Manual command block (this script does not edit /etc/hosts):")"
    echo "sudo tee -a /etc/hosts >/dev/null <<'EOF'"
    printf "%s" "$host_lines"
    echo "EOF"
    if ((ingress_host_count > 1)); then
      echo
      common_ip="$(awk 'NR==1{print $1}' <<< "$host_lines")"
      echo "Optional compact form:"
      echo "${common_ip} ${ingress_hosts[*]}"
      echo "(single line is valid; one-line-per-host is easier to review)"
    fi
  fi

  print_section "Useful Commands"
  echo "- Argo CD initial admin password:"
  echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
  echo "- Current kubectl context:"
  echo "  kubectl config current-context"
  echo "- Default dev credentials from repo (unless overridden during install):"
  echo "  Gitea: ${configured_gitea_user:-gitops-admin} / ${configured_gitea_password:-<unknown>}"
  echo "  MinIO: minioadmin / minioadmin123"
}

main "$@"
