# Monitoring Layer

`infra/monitoring/` defines the shared platform monitoring stack in namespace
`monitoring`.

## Composition

`application.yaml` defines a multi-source Argo CD application named
`monitoring` in namespace `argocd`. The application enables automated
prune/self-heal, sets `CreateNamespace=true`, sets `ServerSideApply=true`, and
combines:

- `kube-prometheus-stack` chart `67.10.0`
- `loki` chart `6.27.0`
- `promtail` chart `6.17.0`
- repo-managed manifests under `infra/monitoring/manifests/`

`kustomization.yaml` includes the Argo CD application only.

## Namespace And Access

- `manifests/namespace.yaml` creates namespace `monitoring`
- `istio-injection: disabled` is set on the monitoring namespace
- Grafana is exposed by `kube-prometheus-stack-grafana` as a `LoadBalancer`
  service on `172.29.0.205`
- `manifests/virtualservice-grafana.yaml` also exposes Grafana at
  `http://grafana.platform.local` through
  `knative-serving/knative-ingress-gateway`
- Grafana admin defaults come from
  `values/kube-prometheus-stack-values.yaml`:
  - username `admin`
  - password `grafanaadmin123`
- Prometheus, Alertmanager, Loki, and Promtail remain cluster-internal

## Metrics Path

`values/kube-prometheus-stack-values.yaml` configures:

- default alert rules enabled
- single-replica Alertmanager with `4h` retention and `2Gi` PVC
- single-replica Prometheus with `4h` retention and `10Gi` PVC
- persistent Grafana with `2Gi` PVC
- Prometheus Operator `PrometheusRule` admission webhook enabled with
  cert-manager-managed TLS
- kube-apiserver scraping skips TLS verification for the local Kind
  control-plane endpoint
- `prometheus-node-exporter` disabled
- `kubeEtcd`, `kubeControllerManager`, and `kubeScheduler` disabled
- laptop-scale resource requests and limits for Prometheus Operator,
  kube-state-metrics, Prometheus, and Grafana

### Additional Scrape Jobs

Prometheus `additionalScrapeConfigs` adds two repo-defined pod discovery jobs:

- `platform-annotated-pods`
  Scrapes pods in `argocd`, `argo`, `istio-system`, `knative-serving`,
  `kserve`, `minio`, and any namespace matching `ml-team-*` when
  `prometheus.io/scrape: "true"` is present. `prometheus.io/path` and
  `prometheus.io/port` override the default path and target port. Pods labeled
  with `workflows.argoproj.io/workflow` are excluded from this job.
- `kserve-runtime-pods`
  Scrapes pods in `kserve` and any namespace matching `ml-team-*` when
  `prometheus.kserve.io/port` is present. `prometheus.kserve.io/path` sets the
  metrics path.

### Repo-Managed Scrape Resources

`manifests/scrape/` adds monitoring resources that are not provided by the
Helm chart defaults:

- `ServiceMonitor/argocd`
  Scrapes `argocd-metrics`, `argocd-server-metrics`, and
  `argocd-repo-server` services in namespace `argocd`
- `Service/workflow-controller-metrics`
  Creates a metrics service for the Argo workflow controller in namespace
  `argo`
- `ServiceMonitor/argo-workflows`
  Scrapes the workflow-controller metrics service in namespace `argo` over
  HTTPS
- `ServiceMonitor/prometheus-operator`
  Scrapes the Prometheus Operator HTTPS endpoint in namespace `monitoring`
  with TLS verification disabled for the self-monitor path

## Logs Path

`values/loki-values.yaml` configures:

- single-binary Loki
- filesystem-backed TSDB storage
- `8Gi` persistence
- `4h` retention
- gateway disabled
- Loki canary, tests, caches, and rule sidecar disabled

`values/promtail-values.yaml` configures:

- Promtail as a `DaemonSet`
- log shipping to
  `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`
- namespace filtering to `argocd`, `argo`, `istio-system`,
  `knative-serving`, `kserve`, `metallb-system`, `minio`, `monitoring`,
  and any namespace matching `ml-team-*`
- Promtail self-log exclusion
- exclusion of pods labeled with `workflows.argoproj.io/workflow`
- pod-phase filter limited to `Pending|Running`
- same-node target filtering via `${HOSTNAME}`
- `ServiceMonitor` enabled for Promtail itself

Team-scoped monitoring selectors use the namespace regex `ml-team-.*`, so a
new tenant namespace that follows the repo naming convention is included
without monitoring-specific edits.

## Dashboards

`manifests/dashboards/` contains repo-managed Grafana dashboard `ConfigMap`
objects. Grafana sidecar dashboard loading is enabled in
`values/kube-prometheus-stack-values.yaml` and watches:

- label `grafana_dashboard`
- annotation `grafana_folder`

Loaded dashboards:

- `Platform / Cluster Health`
- `Platform / Argo CD`
- `Platform / Argo Workflows`
- `Platform / KServe + Knative`
- `Platform / MLflow + MinIO`
- `Platform / Logs`

Prometheus is the datasource for the platform dashboards. Loki is the
datasource for `Platform / Logs`.

## Alerts

`manifests/alerts/prometheusrule-platform.yaml` defines:

- `ArgoAppOutOfSync`
- `ArgoAppDegraded`
- `WorkflowFailureRatioHigh`
- `KServe5xxRateHigh`
- `InferenceLatencyP95High`
- `CriticalNamespaceCrashLoop`
- `MinioUnavailable`
- `CriticalScrapeTargetDown`

## Local Profile Defaults

- only Grafana is exposed outside the cluster
- monitoring retention is capped at `4h` to keep local PVC growth bounded
- Prometheus Operator admission for `PrometheusRule` resources is enabled
  and uses cert-manager-managed TLS
- kube-apiserver scraping skips TLS verification to tolerate local
  control-plane cert/IP mismatches
- `bootstrap/install.sh` applies best-effort Kind node `nofile` and `inotify`
  tuning for this stack

## Related Paths

- `application.yaml`
- `values/kube-prometheus-stack-values.yaml`
- `values/loki-values.yaml`
- `values/promtail-values.yaml`
- `manifests/scrape/`
- `manifests/alerts/`
- `manifests/dashboards/`
