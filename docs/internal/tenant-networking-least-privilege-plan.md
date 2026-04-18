# Tenant Networking And Least-Privilege Plan

## Purpose

This document explains the current tenant networking behavior in the local Kind
profile and defines a staged plan to move the repo toward least privilege
without breaking the existing MLflow -> Argo Workflows -> GitOps -> KServe
flow.

This is an internal engineering note. It is intentionally detailed because the
current diagram work exposed a real design gap: tenant-local execution is
working as intended, but traffic inside tenant namespaces is still broader than
necessary.

## Scope

Current focus:

- `ml-team-a`
- central workflow hub in `argo`
- GitOps control plane in `argocd`
- serving control plane in `istio-system`, `knative-serving`, and `kserve`
- tenant-local MLflow, workflow pods, and model-serving pods in `ml-team-a`

This same model will apply to additional tenant namespaces such as `ml-team-b`
once enabled.

## Executive Summary

The current design is central dispatch with tenant-local execution.

- Argo Workflows hub logic runs in namespace `argo`.
- The hub discovers tenant configs, then creates tenant `Workflow` objects in
  each tenant namespace.
- For Team A, that means workflow pods run in `ml-team-a`, not in `argo`.
- This is deliberate and matches the repo's current ownership model.

The current security posture is acceptable for a local demo, but it is not yet
least privilege.

- Tenant workflow pods have reasonably narrow Kubernetes RBAC.
- The tenant namespace has a default `NetworkPolicy`, but it still allows all
  pods in the same tenant namespace to talk to each other.
- As a result, `mlflow`, workflow pods, and model-serving pods in `ml-team-a`
  are not yet isolated from each other.
- There are no checked-in Istio `AuthorizationPolicy`,
  `PeerAuthentication`, `RequestAuthentication`, or `Sidecar` resources in the
  repo today.

The target direction should be:

1. Keep central dispatch in `argo`.
2. Keep tenant-local execution in `ml-team-a`.
3. Replace broad same-namespace traffic with role-based allow rules.
4. Use Kubernetes `NetworkPolicy` as the hard deny layer.
5. Add Istio mTLS and `AuthorizationPolicy` after the L3/L4 policy is stable.

## Namespace Roles And Mesh Behavior

### `argo`

Role:

- central Argo Workflows control plane
- hosts `workflow-controller`
- hosts `argo-server`
- hosts `CronWorkflow/mlflow-tag-sync-hub`

Injection behavior:

- the namespace itself is not labeled for blanket Istio injection
- `infra/argo-workflows/namespace.yaml`
- selected workflow pods are explicitly annotated for injection in:
  - `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`
  - `infra/argo-workflows/templates/mlflow-tag-sync-workflow.yaml`
  - `infra/argo-workflows/templates/mlflow-tag-prune-workflow.yaml`

Practical meaning:

- do not treat the whole `argo` namespace as automatically injected
- do treat the hub workflow pod and child workflow step pods as injected

### `argocd`

Role:

- Argo CD control plane
- watches Git in Gitea
- renders and applies repo state into the cluster

Injection behavior:

- no checked-in namespace-wide injection behavior was found
- not treated as a tenant workload namespace

### `ml-team-a`

Role:

- tenant namespace
- hosts MLflow
- hosts tenant-local workflow step pods
- hosts tenant-local KServe `InferenceService` resources
- hosts Knative/KServe runtime pods created for model serving

Injection behavior:

- namespace-wide auto-injection is enabled in `teams/ml-team-a/namespace.yaml`
- MLflow also has an explicit sidecar annotation in
  `infra/mlflow/base/values.yaml`

Practical meaning:

- MLflow pods should be injected
- workflow step pods in this namespace should be injected
- Knative/KServe-serving pods created in this namespace should be treated as
  mesh-participating runtime workloads

### `monitoring`

Role:

- Prometheus, Grafana, Loki, Promtail

Injection behavior:

- explicitly disabled in `infra/monitoring/manifests/namespace.yaml`

Practical meaning:

- Grafana can still be routed through the Istio/Knative ingress path by a
  `VirtualService`
- that does not mean Grafana is sidecar-injected

### `istio-system`

Role:

- Istio control plane
- Istio ingress gateway

Injection behavior:

- this is native Istio infrastructure, not normal application sidecar
  injection

Practical meaning:

- the ingress gateway is part of the data plane
- it is not an app workload that happens to get an extra sidecar

### `knative-serving`

Role:

- Knative Serving control plane
- `net-istio` integration
- ingress routing integration for serverless serving

Injection behavior:

- not modeled as a tenant application namespace
- acts as part of the serving control plane

### `kserve`

Role:

- KServe control plane
- controller and admission behavior for `InferenceService`

Injection behavior:

- do not treat `kserve` as "where model-serving pods live"
- model-serving runtime pods live in the tenant namespace, not in `kserve`

## Why Workflow Pods Appear In `ml-team-a`

This is expected and intentional.

The hub workflow in `argo` reads the tenant descriptor and uses the tenant's
declared namespace when it creates child `Workflow` resources.

Evidence:

- `teams/ml-team-a/tenant-config.yaml` contains:
  - `tenant: ml-team-a`
  - `namespace: ml-team-a`
  - `trackingUri: http://mlflow.ml-team-a.svc.cluster.local`
- `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml` creates:
  - prune `Workflow` objects with `metadata.namespace: {{inputs.parameters.namespace}}`
  - sync `Workflow` objects with `metadata.namespace: {{inputs.parameters.namespace}}`
- `infra/argo-workflows/cron/rbac-mlflow-tag-sync-dispatcher.yaml` gives the
  dispatcher service account in `argo` cluster-wide permission to create
  `workflows`

Operationally, the pattern is:

1. Hub pod runs in `argo`.
2. Hub lists tenant config `ConfigMap` objects across namespaces.
3. Hub connects to each tenant MLflow tracking URI to discover deployable
   models.
4. Hub creates tenant-local `Workflow` objects in `ml-team-a`.
5. The Argo workflow controller creates the step pods in `ml-team-a`.

This is the correct mental model for the diagram:

- `argo` is the central workflow control plane
- `ml-team-a` is the tenant runtime plane for workflow execution and model
  serving

## Current Control Flow

### 1. Tenant discovery

The hub cron workflow runs in `argo` and:

- lists `ConfigMap` objects labeled `platform.ai-ml/tenant-config=true`
- reads each tenant's:
  - namespace
  - tracking URI
  - alias
  - workflow script ConfigMap name
  - Git secret name
  - MLflow secret name

Relevant files:

- `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`
- `teams/ml-team-a/tenant-config.yaml`

### 2. Model discovery

Still inside the hub workflow in `argo`, the `discover-models` step:

- connects to `trackingUri`
- performs a reachability preflight
- queries the MLflow registry
- filters registered models by:
  - alias resolution success
  - presence of `kserve.intent.mode`
  - presence of inline intent payload or artifact ref

Relevant code:

- `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`
- `infra/argo-workflows/scripts/resolve_alias_and_intent.py`

### 3. Tenant workflow submission

For each tenant poll, the hub submits:

- one `mlflow-tag-prune-*` workflow
- one `mlflow-tag-sync-*` workflow per discovered model

These workflows are created in `ml-team-a`.

### 4. Tenant workflow execution

The child workflows run in `ml-team-a` with tenant-local:

- service account `mlflow-tag-sync`
- role and rolebinding
- script `ConfigMap`
- Git credentials secret
- MLflow/MinIO credentials secret

Relevant files:

- `teams/ml-team-a/workflows/kustomization.yaml`
- `teams/_bases/workflows/kustomization.yaml`
- `teams/_bases/workflows/rbac-mlflow-tag-sync.yaml`
- `teams/ml-team-a/workflows/secret-mlflow-sync-git-credentials.yaml`
- `teams/ml-team-a/mlflow/secret-s3-credentials.yaml`

### 5. Git writeback

The sync and prune workflows clone the in-cluster Gitea repo, modify tenant
paths under `apps/tenants/ml-team-a/`, commit, and push.

Relevant files:

- `infra/argo-workflows/scripts/git_writeback.sh`
- `infra/argo-workflows/scripts/git_prune_manifests.sh`
- `teams/ml-team-a/workflows/secret-mlflow-sync-git-credentials.yaml`

### 6. GitOps reconciliation

Argo CD in `argocd` watches the same Gitea repo and applies:

- `teams/ml-team-a` via `Application/ml-team-a-root`
- `apps/tenants/ml-team-a` via `Application/ml-team-a-deployments`

Relevant files:

- `infra/argocd/application-ml-team-a-root.yaml`
- `teams/ml-team-a/models/application-ml-team-a-deployments.yaml`

### 7. Serving

KServe and Knative reconcile the tenant `InferenceService` resources into
runtime serving resources in `ml-team-a`.

The repo's serving path is serverless + mesh-integrated:

- KServe `InferenceService`
- Knative Serving
- Istio ingress gateway

Relevant files:

- `infra/kserve/application.yaml`
- `infra/knative/application-serving-core.yaml`
- `infra/knative/application-istio.yaml`
- `teams/ml-team-a/models/README.md`

## Current Connection Matrix

This section describes what each workload currently needs to reach in order for
the existing design to function.

### External Developer Access

Source: developer workstation

Required destinations:

- `argocd/argocd-server` via LB `172.29.0.200`
- `gitea/gitea-http` via LB `172.29.0.201`
- `gitea/gitea-ssh` via LB `172.29.0.202`
- `istio-system/istio-ingressgateway` via LB `172.29.0.203`
- `minio/minio` via LB `172.29.0.204`
- `monitoring/kube-prometheus-stack-grafana` via LB `172.29.0.205`

Purpose:

- operator access, debugging, and direct endpoint use

### Argo CD Control Plane (`argocd`)

Source workloads:

- `argocd-application-controller`
- `argocd-repo-server`
- supporting Argo CD services

Required destinations:

- Kubernetes API
- Gitea repo URL `http://gitea-http.gitea.svc.cluster.local:3000/gitops-admin/ai-ml.git`

Purpose:

- read Git state
- render manifests
- reconcile cluster state

Current repo evidence:

- `infra/argocd/application-ml-team-a-root.yaml`
- `teams/ml-team-a/models/application-ml-team-a-deployments.yaml`

### Argo Hub / Dispatcher (`argo`)

Source workloads:

- `CronWorkflow/mlflow-tag-sync-hub`
- dispatcher service account `mlflow-tag-sync-dispatcher`

Required destinations:

- Kubernetes API
- tenant MLflow service `http://mlflow.ml-team-a.svc.cluster.local`

Purpose:

- list tenant configmaps across namespaces
- create `Workflow` objects in tenant namespaces
- discover deployable models by querying tenant MLflow

Current repo evidence:

- `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`
- `infra/argo-workflows/cron/rbac-mlflow-tag-sync-dispatcher.yaml`
- `teams/ml-team-a/tenant-config.yaml`

### Tenant Workflow Pods (`ml-team-a`)

Source workloads:

- `mlflow-tag-sync-*`
- `mlflow-tag-prune-*`

Required destinations:

- Kubernetes API
- MLflow service in the same namespace
- Gitea HTTP service
- DNS
- possibly MinIO directly for artifact-ref resolution

Purpose by step:

- `resolve-alias-and-intent`
  - talks to MLflow
  - may download artifact-ref payloads
  - mounts `mlflow-s3-credentials`
- `status-accepted`
  - talks to MLflow
- `render-manifest`
  - local-only transformation
- `status-rendered`
  - talks to MLflow
- `validate-manifest`
  - optionally calls `kubectl apply --dry-run=server`
- `writeback-manifest`
  - clones and pushes to Gitea
- `persist-idempotency-state`
  - currently disabled
- `finalize-status`
  - writes final tags back to MLflow
- `prune-stale-manifests`
  - clones and pushes to Gitea

Current repo evidence:

- `infra/argo-workflows/templates/mlflow-tag-sync-workflow.yaml`
- `infra/argo-workflows/templates/mlflow-tag-prune-workflow.yaml`
- `infra/argo-workflows/scripts/resolve_alias_and_intent.py`
- `infra/argo-workflows/scripts/update_mlflow_status.py`
- `infra/argo-workflows/scripts/git_writeback.sh`
- `infra/argo-workflows/scripts/git_prune_manifests.sh`

Important nuance:

`resolve_alias_and_intent.py` uses `mlflow.artifacts.download_artifacts(...)`
for artifact-ref mode. The workflow template also mounts direct MinIO
credentials. That means the safe assumption for current policy design is that
workflow pods may need both:

- MLflow tracking server access
- MinIO artifact access

This should be re-verified live before tightening egress all the way down.

### Tenant MLflow (`ml-team-a`)

Source workload:

- MLflow deployment pod

Required destinations:

- MinIO in namespace `minio`
- DNS

Required inbound callers:

- Argo hub pod in `argo` for model discovery
- tenant workflow pods in `ml-team-a` for status updates and alias resolution
- Istio ingress path for external UI/API access

Purpose:

- registry and tracking API
- artifact proxying/backing store access

Current repo evidence:

- `infra/mlflow/base/values.yaml`
- `teams/ml-team-a/mlflow/secret-s3-credentials.yaml`
- `teams/ml-team-a/mlflow/virtualservice-mlflow.yaml`
- `teams/_bases/tenant-core/networkpolicy-mlflow-allow-argo.yaml`

### Tenant KServe / Knative Runtime Pods (`ml-team-a`)

Source workloads:

- predictor / runtime pods created from `InferenceService`

Required destinations:

- MinIO for model artifact download when `storageUri` is `s3://...`
- DNS
- mesh/control-plane services required by Knative/Istio runtime behavior

Required inbound callers:

- ingress/data-plane traffic from the Istio/Knative serving path

Purpose:

- load model artifacts
- serve inference traffic

Current repo evidence:

- `infra/argo-workflows/scripts/render_inferenceservice.py`
- `apps/tenants/ml-team-a/deployments/kserve-storage-sa.yaml`
- `teams/ml-team-a/models/README.md`

Important nuance:

The repo intentionally assigns `serviceAccountName: kserve-storage-sa` when the
rendered `InferenceService` uses `s3://...` storage. That service account is
bound to the `mlflow-s3-credentials` secret and carries the expected KServe S3
annotations.

### KServe Control Plane (`kserve`)

Source workloads:

- KServe controller and webhooks

Required destinations:

- Kubernetes API
- Knative Serving control plane

Purpose:

- reconcile `InferenceService` resources
- manage admission/controller behavior

Important scope note:

- `kserve` is not the namespace where Team A predictor pods run
- do not model `kserve` as the tenant-serving runtime namespace

### Knative Serving Control Plane (`knative-serving`)

Source workloads:

- Knative Serving controllers
- `net-istio` integration pieces

Required destinations:

- Kubernetes API
- Istio control plane / ingress path
- tenant workloads for routing and activation

Purpose:

- serverless route management
- revision/service orchestration
- mesh integration

### Istio Control Plane / Ingress (`istio-system`)

Source workloads:

- `istiod`
- `istio-ingressgateway`

Required destinations:

- tenant services and serving backends
- Knative-managed routes

Purpose:

- ingress gateway
- traffic routing
- mesh control plane

### Monitoring (`monitoring`)

Source workloads:

- Grafana
- Prometheus
- Loki
- Promtail

Required destinations:

- scrape targets across platform and tenant namespaces
- Grafana is also exposed through a `VirtualService`

Important scope note:

- the namespace is explicitly labeled `istio-injection: disabled`
- routed-through-ingress does not mean injected

## Current Enforcement Mechanisms

### 1. Namespace-level injection

Current checked-in namespace labels:

- `ml-team-a`: `istio-injection: enabled`
- `ml-team-b`: `istio-injection: enabled`
- `monitoring`: `istio-injection: disabled`

The repo does not currently define namespace manifests for blanket injection in
`argo`, `argocd`, `kserve`, or `knative-serving`.

### 2. Pod-level injection

Workflow pods are explicitly annotated for injection:

- hub pod in `argo`
- sync workflow step pods
- prune workflow step pods

### 3. Kubernetes RBAC

Tenant workflow pods in `ml-team-a` use service account `mlflow-tag-sync`.

Current tenant role permissions are limited to:

- `configmaps`
- `inferenceservices`
- `workflowtaskresults`

This is a good start. RBAC is already narrower than the current network policy.

### 4. Kubernetes NetworkPolicy

Current tenant baseline policy:

- `teams/_bases/tenant-core/networkpolicy.yaml`

What it does now:

- selects all pods in the tenant namespace
- allows ingress from:
  - all pods in the same namespace
  - `istio-system`
  - `knative-serving`
- allows egress to:
  - all pods in the same namespace
  - `istio-system`
  - `knative-serving`
  - MinIO on TCP `9000`
  - Gitea on TCP `3000`
  - kube-dns on TCP/UDP `53`

Current tenant MLflow exception:

- `teams/_bases/tenant-core/networkpolicy-mlflow-allow-argo.yaml`

What it does now:

- allows ingress to MLflow pods from namespace `argo`

Current workflow API egress exception:

- `teams/_bases/workflows/networkpolicy-kube-api-egress.yaml`

What it does now:

- allows workflow pods to reach:
  - Kubernetes service VIP range on TCP `443`
  - Kind Docker subnet on TCP `443` and `6443`

### 5. What is not currently enforced

No checked-in resources were found for:

- `AuthorizationPolicy`
- `PeerAuthentication`
- `RequestAuthentication`
- Istio `Sidecar`

That means:

- no mesh-level workload identity allow/deny rules are in repo
- no repo-managed strict mTLS posture is currently defined here
- same-namespace tenant traffic is currently broader than required

## Current Security Gaps

### Gap 1: same-namespace traffic is still broad

Because `tenant-default` allows:

- ingress from `podSelector: {}`
- egress to `podSelector: {}`

all pods in `ml-team-a` can currently talk to each other unless a more specific
policy changes that behavior.

Practical consequence:

- MLflow can talk directly to tenant-serving pods
- workflow pods can talk directly to tenant-serving pods
- any future tenant-local support pod would inherit the same broad access

This is the main least-privilege gap.

### Gap 2: MinIO and Gitea egress are granted at namespace scope

The current tenant policy allows every pod in `ml-team-a` to egress to:

- MinIO on port `9000`
- Gitea on port `3000`

That is broader than required.

Expected narrower intent:

- MLflow should reach MinIO
- workflow resolve may need MinIO
- workflow writeback/prune needs Gitea
- serving runtime pods need MinIO
- generic tenant pods should not automatically inherit both

### Gap 3: MLflow ingress is broader than it should be

Current actual MLflow callers should be limited to:

- Argo hub discovery pods in `argo`
- tenant workflow pods in `ml-team-a`
- ingress path from `istio-system`

Current same-namespace allow means any tenant-local pod can still call MLflow.

### Gap 4: predictor/runtime pods are not isolated from other tenant workloads

The intended serving path is:

- external client
- Istio ingress gateway
- Knative/KServe routing
- predictor/runtime pod

There is no product requirement that MLflow or tenant workflow pods directly
call the predictor pod over the cluster network. The current namespace policy
still allows it.

### Gap 5: mesh policy is absent

Even after tightening Kubernetes `NetworkPolicy`, there is no current mesh-layer
authorization. For injected workloads, that means:

- there is no repo-managed service identity policy yet
- there is no repo-managed mTLS posture yet

This should be treated as the second layer, not the first layer.

## Target Security Model

The target model should preserve the current architecture:

- central workflow scheduling and dispatch in `argo`
- tenant-local workflow execution in each tenant namespace
- tenant-local model serving in the tenant namespace
- GitOps reconciliation in `argocd`

But traffic should be constrained by workload role.

### Target roles inside a tenant namespace

Each tenant namespace should be segmented at least into these roles:

- `mlflow`
- `workflow`
- `serving-runtime`
- optional future `notebook` or `job` roles

The repo already has some stable labels:

- MLflow pods typically use `app.kubernetes.io/name: mlflow`
- workflow pods carry `workflows.argoproj.io/workflow`

Serving-runtime selectors need live verification before final policy is written.
Use live pod labels from:

- KServe/Knative predictor pod
- Knative revision pod
- stable Service selectors in front of the runtime pod if they are more durable

before locking down selectors.

Important clarification:

- `queue-proxy` is a sidecar container in the same pod, not a separate pod
- Kubernetes `NetworkPolicy` is pod-scoped, not container-scoped
- that means policy can isolate the serving pod from other pods, but it cannot
  separately isolate `queue-proxy` from the user container inside the same pod

### Target allowed traffic

#### MLflow

Allow ingress from:

- `argo` hub discovery pods
- tenant workflow pods
- `istio-system` ingress path

Allow egress to:

- MinIO
- DNS
- any mesh/control-plane destinations still required by the injected MLflow pod
  and proven necessary at runtime

Deny:

- direct access from generic tenant pods
- direct access from serving-runtime pods unless a specific functional need is
  proven

#### Tenant workflow pods

Allow egress to:

- MLflow
- Gitea
- Kubernetes API
- DNS
- MinIO only if artifact-ref path still requires it
- any mesh/control-plane destinations still required by injected workflow pods
  and proven necessary at runtime

Allow ingress from:

- none beyond what the workflow system itself requires

Deny:

- direct calls to serving-runtime pods
- broad same-namespace access

Default recommendation:

- treat external `http://` or `https://` artifact refs as out of scope for the
  least-privilege baseline unless there is a deliberate allowlist requirement

#### Serving-runtime pods

Allow ingress from:

- Istio/Knative serving path only

Allow egress to:

- MinIO
- DNS
- any strictly required control-plane destinations proven necessary for runtime

Deny:

- direct inbound from MLflow
- direct inbound from tenant workflow pods
- broad same-namespace access

#### Generic tenant pods

Allow only what the specific workload needs.

Do not inherit:

- Gitea access
- MinIO access
- MLflow access
- serving-runtime access

### Target enforcement layers

Layer 1:

- Kubernetes `NetworkPolicy`
- hard deny at L3/L4
- primary safety net
- only after confirming the active CNI in this Kind profile actually enforces
  both ingress and egress policy

Layer 2:

- Istio `PeerAuthentication`
- Istio `AuthorizationPolicy`
- optional Istio `Sidecar` resources for egress scoping

Layer 3:

- Kubernetes RBAC
- keep current tenant-local workflow RBAC narrow

## Implementation Checklist

This section is ordered by dependency, not by calendar timeline.

### Check prerequisites before tightening anything

Before relying on the policy model, confirm:

- the active CNI in this Kind profile enforces both ingress and egress
  `NetworkPolicy`
- current live labels on:
  - MLflow pod
  - workflow pods
  - KServe/Knative predictor pod
  - Knative revision pod
- current live source pods and namespaces for the serving ingress path
- whether workflow artifact-ref resolution reaches:
  - MLflow only
  - or MinIO directly as well
- whether any non-injected pod currently reaches MLflow

Deliverable:

- a label and traffic inventory table for `mlflow`, `workflow`, and
  `serving-runtime`

Reason:

- `NetworkPolicy` selectors must target stable labels
- this avoids breaking serving by guessing wrong at runtime labels
- the document should not claim hard-deny behavior unless the cluster actually
  enforces it

### Add explicit role-based allow policies first

Add new allow policies while leaving the current broad tenant-default
same-namespace access in place.

Add at least:

- `NetworkPolicy/mlflow-allow-workflows`
- `NetworkPolicy/mlflow-allow-ingressgateway`
- `NetworkPolicy/workflow-egress-mlflow`
- `NetworkPolicy/workflow-egress-gitea`
- `NetworkPolicy/workflow-egress-dns`
- `NetworkPolicy/workflow-egress-minio` if still required
- `NetworkPolicy/serving-runtime-egress-minio`
- `NetworkPolicy/serving-runtime-ingress-mesh`

Reason:

- additive allow policies are lower risk
- they establish the intended steady-state shape before deny-tightening happens

Verification:

- manual sync still succeeds
- prune still succeeds
- model still serves
- MLflow UI still reachable through ingress

### Tighten `argo` namespace scope, not only tenant scope

The current MLflow exception allows ingress from namespace `argo`, which is
broader than "hub only".

Desired end state:

- hub discovery pods in `argo` can reach tenant MLflow
- unrelated pods in `argo` do not automatically inherit that access
- `argo` egress is limited to Kubernetes API and tenant MLflow, plus any
  proven mesh/control-plane dependencies

Practical note:

- this requires a stable selector for the hub workflow pods, not only a
  namespace selector

Verification:

- hub discovery still works
- child workflow submission still works
- no other `argo` workload can directly reach tenant MLflow unless explicitly
  allowed

### Tighten MLflow ingress explicitly

Replace implicit same-namespace MLflow access with explicit allow rules.

MLflow should allow ingress from:

- hub discovery pods in `argo`
- workflow pods in the same tenant namespace
- ingress/data-plane pods that actually source traffic into MLflow

Important clarification:

- the `VirtualService` is bound to `knative-serving/knative-ingress-gateway`
- the source pods seen by `NetworkPolicy` are expected to be data-plane pods,
  typically in `istio-system`
- policy should be written against the source pods and namespaces that actually
  carry traffic, not only against the gateway config object's namespace

MLflow should not generally allow ingress from:

- serving-runtime pods
- arbitrary tenant-local pods

Reason:

- MLflow is a registry/API surface, not a general east-west endpoint

Verification:

- hub discovery still works
- workflow status updates still work
- MLflow UI/API still works through ingress
- direct pod-to-pod access from unrelated tenant pod to MLflow is denied

### Narrow workflow egress

Scope workflow pod egress down to only what the workflow needs.

Expected workflow egress:

- Kubernetes API
- MLflow
- Gitea
- DNS
- MinIO only if still proven necessary
- any proven mesh/control-plane destinations still required by injected
  workflow pods

Remove:

- broad same-namespace egress
- arbitrary outbound HTTP(S) artifact fetches unless there is a separate
  allowlist policy for them

Reason:

- workflow pods are the most privileged tenant-local runtime today from a
  network perspective because they currently inherit broad namespace access

Verification:

- sync path succeeds end-to-end
- prune path succeeds
- dry-run validation still succeeds
- workflow pod cannot directly curl predictor service

### Narrow serving-runtime ingress and egress

Scope model-serving pods so they are not general east-west endpoints.

Serving-runtime ingress should come from:

- Knative / Istio serving path only

Serving-runtime egress should go to:

- MinIO
- DNS
- proven control-plane endpoints only if actually needed

Reason:

- the predictor should serve inference traffic, not act as a generally
  reachable tenant service

Verification:

- health endpoint still works through ingress IP + `Host` header
- inference request still works
- MLflow pod cannot directly reach predictor
- workflow pod cannot directly reach predictor

### Remove broad same-namespace allow from `tenant-default`

Only after the role-specific policies are verified should the broad tenant
policy be tightened.

Specifically remove:

- ingress from `podSelector: {}`
- egress to `podSelector: {}`

Keep only:

- explicit mesh/control-plane allowances
- DNS
- explicit role-based policies

Reason:

- this is the step that actually closes the main least-privilege gap
- it should happen only after all required allow paths exist

Verification:

- full end-to-end deployment still works
- no unexpected regressions in serving or Git writeback

### Add the Istio security layer after L3/L4 is explicit

Once Kubernetes `NetworkPolicy` is correct, add mesh policy for injected
workloads.

Recommended implementation order:

1. Add namespace- or workload-scoped `PeerAuthentication` in permissive mode
   only if needed for transition.
2. Move to `STRICT` mTLS for tenant workloads once all relevant callers are
   confirmed to be mesh-participating.
3. Add `AuthorizationPolicy` for:
   - MLflow
   - serving-runtime endpoints
4. Optionally add Istio `Sidecar` resources to constrain outbound clusters for
   tenant workloads if needed.

Reason:

- `NetworkPolicy` should remain the hard deny layer
- Istio authz then gives workload identity-based control for injected traffic

Important caution:

- do not start with Istio policy alone
- non-injected callers and ambiguous transition states are easier to debug when
  L3/L4 policy is already explicit

### Keep repeatable verification checks with the plan

Add repeatable checks so future repo changes do not silently widen access
again.

Recommended checks:

- end-to-end champion sync
- prune path
- MLflow UI reachability via ingress
- inference via ingress
- negative tests:
  - unrelated tenant pod cannot reach MLflow
  - MLflow cannot reach predictor
  - workflow pod cannot reach predictor
  - generic tenant pod cannot reach Gitea
  - generic tenant pod cannot reach MinIO unless explicitly allowed

## Recommended Policy Design Principles

### Principle 1: use pod-role segmentation, not only namespace segmentation

Namespace segmentation is necessary but not sufficient here because:

- MLflow
- workflow pods
- serving pods

all intentionally live in the same tenant namespace.

### Principle 2: prefer additive rollout first

Do not replace the current tenant-default policy in one step.

Safer path:

- add specific allow policies
- verify
- then remove the broad same-namespace rules

### Principle 3: keep `argo` as central control plane, not tenant runtime

Do not "fix" the workflow-pod placement by moving tenant workflows into
`argo`.

That would weaken tenant-local ownership and make tenant-scoped controls harder.

The correct fix is:

- keep execution tenant-local
- narrow the allowed traffic paths around that design

### Principle 4: use Kubernetes policy first, Istio policy second

Reason:

- `NetworkPolicy` covers all pod traffic at the cluster network level
- Istio policy only helps for traffic that is inside the mesh and correctly
  identified
- this only counts as a real control once the active network plugin is
  confirmed to enforce `NetworkPolicy`

### Principle 5: treat diagram and policy as the same source of truth

The diagram should show:

- where workloads run
- which are mesh-participating
- which traffic is allowed

The policy plan should enforce the same story.

If the diagram shows "MLflow does not talk to predictor", the repo should
eventually enforce that statement.

## Concrete Desired Connection Map

This is the target story the repo should eventually implement.

### `argo` namespace

Allowed:

- hub -> Kubernetes API
- hub -> tenant MLflow
- hub -> create tenant workflows in tenant namespaces
- hub -> any proven mesh/control-plane destinations still required by the
  injected hub pod

Not needed:

- hub -> tenant predictor pod
- hub -> Gitea
- hub -> MinIO

Important clarification:

- the goal is "hub pods in `argo`", not "all pods in namespace `argo`"

### `ml-team-a` workflow pods

Allowed:

- workflow -> MLflow
- workflow -> Gitea
- workflow -> Kubernetes API
- workflow -> DNS
- workflow -> MinIO only if artifact-ref requires it
- workflow -> any proven mesh/control-plane destinations still required by the
  injected workflow pod

Not needed:

- workflow -> predictor service/pod
- workflow -> arbitrary same-namespace pods
- workflow -> arbitrary external HTTP(S) destinations unless deliberately
  allowlisted

### `ml-team-a` MLflow

Allowed ingress:

- hub discovery pods in `argo`
- tenant workflow pods
- ingress gateway / mesh path

Allowed egress:

- MinIO
- DNS
- any proven mesh/control-plane destinations still required by the injected
  MLflow pod

Not needed:

- MLflow -> predictor pod
- arbitrary tenant pod -> MLflow

### `ml-team-a` predictor/runtime pods

Allowed ingress:

- serving path from Knative/Istio

Allowed egress:

- MinIO
- DNS
- proven control-plane destinations only if actually required

Not needed:

- direct traffic from MLflow
- direct traffic from workflow pods

### `argocd`

Allowed:

- Argo CD -> Gitea
- Argo CD -> Kubernetes API

Not needed:

- Argo CD -> tenant MLflow
- Argo CD -> predictor pod

## Risks And Open Questions

### Open question 1: exact runtime labels for serving pods

Before finalizing policy selectors, confirm the stable pod labels generated by
the pinned Knative + KServe combination in this repo.

### Open question 2: direct MinIO need for workflow resolve

The current workflow template mounts MinIO credentials and the resolve script
uses MLflow artifact download APIs. The exact traffic path should be verified
live before removing MinIO egress from workflow pods.

### Open question 3: mTLS readiness for all MLflow callers

Before enabling strict mTLS around MLflow, confirm that every intended caller
is injected or otherwise handled correctly.

### Open question 4: `NetworkPolicy` enforcement in the active Kind profile

Before describing Kubernetes policy as the hard deny layer, confirm the active
network plugin actually enforces both ingress and egress policy in this local
cluster profile.

### Open question 5: future tenant-local support workloads

If notebooks, batch jobs, or ad hoc debug pods are added later, they should not
inherit broad tenant privileges by default.

## Source Files Used For This Analysis

- `docs/architecture.md`
- `infra/argo-workflows/README.md`
- `infra/argo-workflows/cron/mlflow-tag-sync-hub-cron.yaml`
- `infra/argo-workflows/cron/rbac-mlflow-tag-sync-dispatcher.yaml`
- `infra/argo-workflows/templates/mlflow-tag-sync-workflow.yaml`
- `infra/argo-workflows/templates/mlflow-tag-prune-workflow.yaml`
- `infra/argo-workflows/scripts/resolve_alias_and_intent.py`
- `infra/argo-workflows/scripts/update_mlflow_status.py`
- `infra/argo-workflows/scripts/git_writeback.sh`
- `infra/argo-workflows/scripts/git_prune_manifests.sh`
- `infra/mlflow/base/values.yaml`
- `infra/kserve/application.yaml`
- `infra/istio/application-ingressgateway.yaml`
- `infra/monitoring/manifests/namespace.yaml`
- `infra/monitoring/manifests/virtualservice-grafana.yaml`
- `teams/ml-team-a/namespace.yaml`
- `teams/ml-team-a/tenant-config.yaml`
- `teams/ml-team-a/workflows/kustomization.yaml`
- `teams/ml-team-a/workflows/secret-mlflow-sync-git-credentials.yaml`
- `teams/ml-team-a/workflows/README.md`
- `teams/ml-team-a/mlflow/secret-s3-credentials.yaml`
- `teams/ml-team-a/mlflow/virtualservice-mlflow.yaml`
- `teams/ml-team-a/models/application-ml-team-a-deployments.yaml`
- `teams/ml-team-a/models/README.md`
- `teams/_bases/tenant-core/networkpolicy.yaml`
- `teams/_bases/tenant-core/networkpolicy-mlflow-allow-argo.yaml`
- `teams/_bases/workflows/kustomization.yaml`
- `teams/_bases/workflows/rbac-mlflow-tag-sync.yaml`
- `teams/_bases/workflows/networkpolicy-kube-api-egress.yaml`
- `apps/tenants/ml-team-a/deployments/kserve-storage-sa.yaml`
