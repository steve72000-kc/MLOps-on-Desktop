# MLflow Layer

`infra/mlflow/` contains the shared MLflow chart values and the static
hostPath-backed PersistentVolumes used by the local profile.

## Composition

`infra/mlflow/kustomization.yaml` renders:

- `pv-ml-team-a.yaml`
- `pv-ml-team-b.yaml`

`infra/mlflow/base/values.yaml` is consumed by team MLflow applications but is
not rendered by this Kustomization.

## Shared Base

`infra/mlflow/base/values.yaml` defines the shared Helm values applied to every
team MLflow release:

- `strategy.type: Recreate`
- sqlite backend path `/mlflow/data/mlflow.db`
- proxied artifact serving
- default artifact destination `/mlflow/data/mlartifacts`
- Istio sidecar injection
- relaxed liveness and readiness probes
- `extraArgs.workers: "1"` as a quoted string

## Static Storage

The local profile uses one static PV per checked-in team:

- `pv-ml-team-a.yaml` -> `PersistentVolume/mlflow-ml-team-a-pv`
- `pv-ml-team-b.yaml` -> `PersistentVolume/mlflow-ml-team-b-pv`

Both PVs are:

- `10Gi`
- `ReadWriteOnce`
- `storageClassName: ""`
- `persistentVolumeReclaimPolicy: Retain`

`bootstrap/install.sh` mounts host `${ROOT_DIR}/.local/minio-data` into every
Kind node at `/var/local/minio-data`. The current PV hostPaths are:

- `/var/local/minio-data/mlflow/ml-team-a`
- `/var/local/minio-data/mlflow/ml-team-b`

## Team Contract

`teams/<team>/mlflow/application.yaml` installs chart `mlflow` version `1.7.3`
from `https://community-charts.github.io/helm-charts` and merges:

- `$values/infra/mlflow/base/values.yaml`
- `$values/teams/<team>/mlflow/values.yaml`

`teams/<team>/mlflow/values.yaml` adds the team-specific runtime settings:

- service account `mlflow-runtime`
- PVC mount `mlflow-data` at `/mlflow/data`
- MinIO-backed artifact root `s3://mlflow-<team>/artifacts`
- existing secret `mlflow-s3-credentials`

`teams/<team>/mlflow/pvc.yaml` binds the team PVC to the matching static PV.

`teams/<team>/mlflow/virtualservice-mlflow.yaml` defines the team MLflow mesh
route.

## Current Repo State

This layer currently checks in static PVs for `ml-team-a` and `ml-team-b`.
Adding another team requires a matching PV under `infra/mlflow/` and a matching
PVC under `teams/<team>/mlflow/`.

## Verification

Render the shared MLflow layer:

```bash
kustomize build infra/mlflow
```

Check the static PVs:

```bash
kubectl get pv | rg 'mlflow-ml-team-(a|b)-pv'
```

Check a team PVC binding:

```bash
kubectl -n ml-team-a get pvc mlflow-data
```

Expected state:

- shared layer render includes both `PersistentVolume` objects
- team PVC status is `Bound`

## Related Paths

- `infra/mlflow/base/README.md`
- `teams/<team>/mlflow/`
- `docs/architecture.md`
