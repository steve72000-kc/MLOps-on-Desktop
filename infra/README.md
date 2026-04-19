# Infra Layer

`infra/` contains the shared platform layer reconciled from
`clusters/kind/bootstrap` through `infra/kustomization.yaml`.

## Composition

`infra/kustomization.yaml` composes:

- `infra/argocd/` for team root Argo CD applications
  and shared Argo CD build options
- `infra/argo-workflows/` for the shared workflow controller install, hub cron,
  workflow templates, and shared scripts
- `infra/cert-manager/` for cert-manager installation
- `infra/istio/` for the Istio base, cert-manager-backed mesh CA path, control
  plane, ingress gateway, and mesh mTLS policy
- `infra/knative/` for Knative Serving and `net-istio`
- `infra/kserve/` for KServe installation and runtime overrides
- `infra/mlflow/` for shared MLflow base values and team storage PVs
- `infra/minio/` for shared object storage and tenant bucket bootstrap
- `infra/monitoring/` for Grafana, Prometheus, Loki, Promtail, and repo-managed
  dashboards and alerts

## Ownership

- `infra/argocd/` defines the team root applications that point Argo CD at
  `teams/<team>/`, plus the shared Argo CD config that `bootstrap/install.sh`
  seeds before `Application/ai-ml-root` is created
- `infra/argo-workflows/` owns the central MLflow alias sync/prune engine used
  by tenant workflows across enabled teams
- `infra/mlflow/base/` owns shared MLflow defaults; team-specific MLflow
  applications and values live under `teams/<team>/mlflow/`
- `infra/kserve/runtime-overrides/` owns platform runtime behavior such as the
  custom MLServer runtime probes
- `infra/istio/` owns the shared mesh CA, `cert-manager-istio-csr`, the Istio
  control plane, and the default mesh mTLS policy
- `infra/monitoring/` owns shared dashboards, scrape configuration, and alerting
  across platform namespaces and tenant namespaces matching `ml-team-*`
- `bootstrap/install.sh` seeds the committed
  `infra/argocd/argocd-cm-kustomize-build-options.yaml` into Argo CD before
  the root app exists; after that, the same `ConfigMap` stays GitOps-owned
  under `infra/argocd/`

## Shared Platform Behavior

- the central sync hub is
  `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`
- tenant discovery is driven by labeled `tenant-config` `ConfigMap` resources
  in team namespaces
- one tenant prune workflow is dispatched per poll and one sync workflow per
  discovered model
- rendered deployment manifests are written under
  `apps/tenants/<team>/deployments/...` through the workflow writeback path
- workflow scripts are owned once under `infra/argo-workflows/scripts/` and
  mounted into tenant workflow pods through the team workflow base

## Local Profile Defaults

- `infra/argocd/kustomization.yaml` enables `ml-team-a-root` and leaves
  `ml-team-b-root` commented out by default
- the Istio ingress gateway is pinned to `172.29.0.203`
- MinIO is pinned to `172.29.0.204`
- Grafana is pinned to `172.29.0.205`
- Istio workload certificates are issued through cert-manager by
  `cert-manager-istio-csr`
- MLflow sqlite persistence uses static hostPath-backed PVs in
  `infra/mlflow/pv-ml-team-a.yaml` and `infra/mlflow/pv-ml-team-b.yaml`
- monitoring keeps the laptop footprint lower by disabling
  `prometheus-node-exporter` and several optional Loki components while only
  Prometheus keeps an Istio sidecar for mTLS-protected scraping without
  enabling mesh traffic interception for the rest of the stack

## Related Docs

- `infra/argocd/README.md`
- `infra/argo-workflows/README.md`
- `infra/istio/README.md`
- `infra/mlflow/README.md`
- `infra/minio/README.md`
- `infra/monitoring/README.md`
