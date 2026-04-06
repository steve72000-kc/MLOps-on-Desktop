# Team A

`teams/ml-team-a/` defines the default enabled tenant profile. The team root
Argo CD application `ml-team-a-root` points at this path.

This path contains:

- `namespace.yaml` for the `ml-team-a` namespace
- `tenant-config.yaml` for tenant-scoped sync inputs including tracking URI,
  sync alias, writeback root, secret names, and artifact destination
- `core/` for shared tenant guardrails from `teams/_bases/tenant-core/`
- `resourcequota.yaml` for the higher-capacity team-a quota profile; it exists
  in this path but is currently not referenced from `kustomization.yaml`
- `mlflow/` for the team MLflow Argo CD application, PVC, S3 credentials
  secret, and routing
- `models/` for the Argo CD child application that reconciles
  `apps/tenants/ml-team-a/...`
- `workflows/` for tenant-local workflow prerequisites and Git credentials;
  the shared workflow base is pulled from `teams/_bases/workflows`, and the
  workflow scripts remain centrally owned under `infra/argo-workflows/scripts/`

Related path outside this directory:

- `apps/tenants/ml-team-a/deployments/` contains workflow-managed
  `InferenceService` manifests written by the shared sync workflow and
  reconciled by `ml-team-a-deployments`

Operational checks:

```bash
kubectl -n argocd get application ml-team-a-root ml-team-a-deployments
kubectl -n ml-team-a get configmap tenant-config
```

Related docs:

- `teams/ml-team-a/mlflow/README.md`
- `teams/ml-team-a/models/README.md`
- `teams/ml-team-a/workflows/README.md`
