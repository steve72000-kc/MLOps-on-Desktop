# Teams Layer

`teams/<team>/` contains team-scoped runtime configuration reconciled by the
team root Argo CD application defined under `infra/argocd/`.

This layer contains:

- `teams/<team>/mlflow/` for the team MLflow application, values, and routing
- `teams/<team>/models/` for Argo CD child applications that reconcile
  `apps/tenants/<team>/...`
- `teams/<team>/workflows/` for tenant workflow runtime prerequisites such as
  service accounts, RBAC, secrets, and references to the shared workflow script
  `ConfigMap` base
- `teams/_bases/` for shared tenant bases
- common tenant resources such as `Namespace`, `ResourceQuota`, `LimitRange`,
  `NetworkPolicy`, and `tenant-config.yaml`

Related path outside this layer:

- `apps/tenants/<team>/...` contains workflow-managed deployment manifests
  written by the shared sync workflow and reconciled by the team deployment app

Profile defaults:

- in-cluster team activation is controlled by
  `infra/argocd/kustomization.yaml`
- `ml-team-a-root` is enabled by default
- `teams/kustomization.yaml` mirrors that profile for local aggregate builds
  only; it is not part of the live Argo CD reconciliation chain
- `./scripts/validate.sh` does not follow that aggregate profile toggle; it
  builds every tracked `kustomization.yaml`, including Team-b paths

Ownership boundaries:

- workflow logic and renderer scripts are centrally owned under
  `infra/argo-workflows/scripts/`
- team `workflows/` directories provide tenant runtime prerequisites and script
  mounting, not duplicate workflow logic
- team `models/` directories define Argo CD wiring from `teams/<team>/` to
  `apps/tenants/<team>/...`
- shared workflow and tenant-core bases now carry the least-privilege
  `NetworkPolicy` set for hub, MLflow, workflow, and serving-runtime roles,
  including explicit `istiod`, `cert-manager-istio-csr`,
  `istio-ingressgateway`, and `activator` selectors

Local build constraint:

- the workflow base reads shared files from `infra/argo-workflows/scripts/*`
- default Kustomize load restrictions block that cross-tree reference
- local builds for a team path require:

```bash
kustomize build --load-restrictor=LoadRestrictionsNone teams/<team>
```

- Argo CD is configured with the same build option in
  `infra/argocd/argocd-cm-kustomize-build-options.yaml`

Team-specific docs:

- `teams/ml-team-a/README.md`
- `teams/ml-team-a/mlflow/README.md`
- `teams/ml-team-a/models/README.md`
- `teams/ml-team-a/workflows/README.md`
- `teams/ml-team-b/workflows/README.md`
