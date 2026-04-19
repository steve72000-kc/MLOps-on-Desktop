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

## Reconciliation Chain

The monitoring namespace is assembled through a GitOps handoff, not by applying
one flat manifest directory directly:

1. `Application/ai-ml-root` tracks `clusters/kind/bootstrap`
2. `clusters/kind/bootstrap` composes `infra/`
3. `infra/kustomization.yaml` includes `infra/monitoring/`
4. `infra/monitoring/application.yaml` creates `Application/monitoring` in
   namespace `argocd`
5. Argo CD renders all monitoring sources into one desired state for namespace
   `monitoring`

This means the main controller for the namespace is Argo CD in namespace
`argocd`. The objects you see in `monitoring` are the result of that render.

## Namespace And Access

- `manifests/namespace.yaml` creates namespace `monitoring`
- the monitoring namespace intentionally carries no `istio-injection` label
  because Istio 1.24 treats `istio-injection: disabled` as stronger than
  pod-level opt-in
- leaving the namespace unlabeled keeps monitoring workloads outside the mesh
  by default while still allowing Prometheus to opt in explicitly
- Prometheus explicitly opts into Istio sidecar injection through
  `prometheus.prometheusSpec.podMetadata`; the pod label is what matches the
  active injector selector
- Prometheus keeps an Istio sidecar only to write short-lived workload
  certificates into a shared volume; inbound and outbound traffic capture stay
  disabled so Prometheus can continue direct pod-IP scraping
- Grafana, Loki, Promtail, Alertmanager, kube-state-metrics, and the
  Prometheus Operator still carry explicit sidecar opt-out labels and
  annotations to keep the local footprint smaller and make the intent obvious
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

## Resource Ownership

The live namespace is a mix of chart-managed resources, operator-managed
resources, and repo-managed resources.

### Argo CD Multi-Source Application

`Application/monitoring` combines five sources into one sync:

- Helm chart `kube-prometheus-stack`
- Helm chart `loki`
- Helm chart `promtail`
- repo manifests under `infra/monitoring/manifests`
- repo values source referenced as `$values`

Argo CD applies the rendered output directly. Helm is used only as a template
source inside the Argo CD sync.

### `kube-prometheus-stack` Ownership

The `kube-prometheus-stack` chart creates most of the metrics stack control
plane:

- `Deployment/kube-prometheus-stack-operator`
- `Deployment/kube-prometheus-stack-grafana`
- `Deployment/kube-prometheus-stack-kube-state-metrics`
- `Prometheus/kube-prometheus-stack-prometheus`
- `Alertmanager/kube-prometheus-stack-alertmanager`
- chart-provided `ServiceMonitor` and `PrometheusRule` resources
- webhook, TLS, RBAC, `ConfigMap`, `Secret`, `Service`, and PVC resources

The Prometheus Operator deployment is a controller. It watches
`Prometheus`, `Alertmanager`, `ServiceMonitor`, and `PrometheusRule`
resources and reconciles generated runtime objects such as:

- `StatefulSet/prometheus-kube-prometheus-stack-prometheus`
- `StatefulSet/alertmanager-kube-prometheus-stack-alertmanager`
- generated rule/config `ConfigMap` and `Secret` objects
- `prometheus-operated` and `alertmanager-operated` services

Prometheus and Alertmanager are therefore managed in two layers: the chart
creates the custom resources, and the Prometheus Operator turns those custom
resources into the running `StatefulSet`, service, secret, and config objects
that Prometheus and Alertmanager need.

### `loki` Ownership

The Loki chart creates Loki directly as storage infrastructure, not through the
Prometheus Operator:

- `StatefulSet/loki`
- `Service/loki`
- `Service/loki-headless`
- `Service/loki-memberlist`
- Loki `ConfigMap` resources
- PVC `storage-loki-0`

This repo configures Loki in single-binary mode, so one `StatefulSet` is the
expected runtime shape.

### `promtail` Ownership

The Promtail chart creates node-local log shippers:

- `DaemonSet/promtail`
- `Service/promtail-metrics`
- `ServiceMonitor/promtail`
- Promtail config `Secret`

Promtail is a `DaemonSet` because it needs one pod per node to tail local
container logs.

### Repo-Managed Manifest Ownership

`infra/monitoring/manifests/` owns the parts that are specific to this repo's
platform wiring:

- namespace `monitoring`
- `VirtualService/grafana`
- extra `ServiceMonitor` resources for Argo CD, Argo Workflows,
  `cert-manager-istio-csr`, and the Prometheus Operator
- `PrometheusRule/platform-monitoring`
- Grafana dashboard `ConfigMap` objects

## How Prometheus Configuration Works

Prometheus in this stack is configured through Kubernetes resources rather than
through one hand-written static config file.

### `ServiceMonitor`

A `ServiceMonitor` tells Prometheus which service endpoints to scrape and how
to scrape them. It is a discovery and configuration object, not a running
workload.

In this repo, `ServiceMonitor` resources are used for:

- chart-provided monitoring targets such as Grafana, Prometheus, kube-state-metrics,
  Alertmanager, Promtail, and core Kubernetes services
- repo-managed targets such as Argo CD, Argo Workflows,
  `cert-manager-istio-csr`, and the Prometheus Operator

### `PrometheusRule`

A `PrometheusRule` contains recording rules and alerting rules. It tells
Prometheus which expressions to evaluate against scraped metrics, but it does
not send traffic to Prometheus itself.

In this repo, `PrometheusRule` resources come from both:

- the default rules bundled with `kube-prometheus-stack`
- platform-specific rules defined under `manifests/alerts/`

### Operator Role

The Prometheus Operator watches `Prometheus`, `ServiceMonitor`,
`PrometheusRule`, and related resources, validates them, and renders the
generated configuration that the Prometheus runtime actually consumes.

In practical terms:

1. `ServiceMonitor` resources define scrape targets
2. `PrometheusRule` resources define rules to evaluate
3. the operator renders those resources into Prometheus runtime config
4. Prometheus scrapes metrics, stores them, evaluates rules, and sends firing
   alerts to Alertmanager

This separation is important because some resources in the namespace are
configuration inputs while others are the long-running processes that serve
dashboards, scrape metrics, or store logs.

## Runtime Flow

### Metrics Flow

1. metric-producing services and pods expose `/metrics` endpoints.
2. `ServiceMonitor` resources and `additionalScrapeConfigs` tell Prometheus
   where those endpoints are.
3. the Prometheus Operator renders that configuration for the
   `Prometheus/kube-prometheus-stack-prometheus` runtime.
4. the Prometheus `StatefulSet` scrapes targets, stores metrics on its PVC, and
   evaluates configured rules.
5. Prometheus sends firing alerts to Alertmanager.
6. Grafana queries Prometheus as a datasource.

Prometheus is the one monitoring workload that joins the mesh in this repo.
The namespace itself stays unlabeled for injection; Prometheus opts in
explicitly through its generated pod template. Its sidecar is used only for
Istio certificate output, not traffic interception. That keeps mTLS-enabled
KServe runtime scrapes working for injected workloads in `kserve` and
`ml-team-*` while merged pod metrics in `istio-system`, `knative-serving`,
`argo`, and other injected namespaces can still be scraped directly. The rest
of the monitoring stack remains outside the mesh.

### Logs Flow

1. `DaemonSet/promtail` tails pod logs on each node.
2. relabel rules keep only the platform and tenant namespaces targeted by this
   repo.
3. Promtail pushes logs to `http://loki.monitoring.svc.cluster.local:3100`.
4. Loki stores log data on its PVC.
5. Grafana queries Loki as the log datasource.

### Dashboard Flow

1. chart-provided and repo-managed dashboard `ConfigMap` objects exist in
   namespace `monitoring`
2. Grafana sidecars watch for `grafana_dashboard=1`
3. dashboards are copied into the Grafana pod and reloaded through the Grafana
   admin API

## Runtime Relationships

At runtime, the important service-to-service relationships are:

- scrape targets -> Prometheus
- Prometheus -> Alertmanager
- Grafana -> Prometheus
- Promtail -> Loki
- Grafana -> Loki

The control and configuration relationships are:

- Argo CD -> rendered monitoring resources
- Prometheus Operator -> Prometheus and Alertmanager runtime objects
- `ServiceMonitor` -> Prometheus scrape configuration
- `PrometheusRule` -> Prometheus rule evaluation
- dashboard `ConfigMap` objects -> Grafana sidecar import path

## Inspecting The Stack

Some important resources in this stack are custom resources or generated
configuration objects, so they do not stand out in a basic workload listing.
Useful resource types to inspect include:

- `Prometheus`
- `Alertmanager`
- `ServiceMonitor`
- `PrometheusRule`
- `ConfigMap`
- `Secret`
- `PersistentVolumeClaim`
- `Issuer` and `Certificate`
- cluster-scoped RBAC and CRD objects

For a fuller inventory, use:

```bash
kubectl -n monitoring get all
kubectl -n monitoring get prometheus,alertmanager,servicemonitor,prometheusrule
kubectl -n monitoring get cm,pvc,secret
```

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
- `ServiceMonitor/cert-manager-istio-csr`
  Scrapes the `cert-manager-istio-csr-metrics` service in namespace
  `istio-system`; this is repo-managed so the scrape object appears only after
  the Prometheus Operator CRDs exist
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
