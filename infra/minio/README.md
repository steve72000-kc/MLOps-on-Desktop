# MinIO Layer

`infra/minio/` defines the shared object storage layer in namespace `minio`.

## Composition

`application.yaml` defines the Argo CD application `minio` in namespace
`argocd`. The application enables automated prune/self-heal, sets
`CreateNamespace=true`, sets `ServerSideApply=true`, and points at
`infra/minio/manifests/`.

`kustomization.yaml` includes the Argo CD application only.

`manifests/` creates:

- root credentials secret `minio-credentials`
- tenant bootstrap credentials secret `minio-tenant-credentials`
- bootstrap script `ConfigMap` `minio-tenant-bootstrap`
- bootstrap `Job` `minio-tenant-bootstrap`
- static `PersistentVolume` `minio-pv`
- `PersistentVolumeClaim` `minio-pvc`
- single-replica `Deployment` `minio`
- `LoadBalancer` `Service` `minio`

## Storage Path

`bootstrap/install.sh` mounts host `${ROOT_DIR}/.local/minio-data` into every
Kind node at `/var/local/minio-data`.

The MinIO data path is:

- host path `${ROOT_DIR}/.local/minio-data/minio`
- Kind node path `/var/local/minio-data/minio`
- `PersistentVolume/minio-pv` hostPath `/var/local/minio-data/minio`
- `PersistentVolumeClaim/minio/minio-pvc`
- container mount `/data`

Current storage profile:

- PV capacity `50Gi`
- PVC request `50Gi`
- `storageClassName: ""`
- `persistentVolumeReclaimPolicy: Retain`

## Runtime

`deployment.yaml` runs MinIO as a single replica with:

- image `quay.io/minio/minio:latest`
- API on `9000`
- console on `9001`
- readiness probe `/minio/health/ready`
- liveness probe `/minio/health/live`
- `Recreate` deployment strategy

`service.yaml` exposes both ports on static `LoadBalancer` IP `172.29.0.204`.

Endpoints:

- in-cluster API `http://minio.minio.svc.cluster.local:9000`
- in-cluster console `http://minio.minio.svc.cluster.local:9001`
- LoadBalancer API `http://172.29.0.204:9000`
- LoadBalancer console `http://172.29.0.204:9001`

## Credentials

`secret.yaml` defines the root credentials used by the MinIO deployment:

- access key `minioadmin`
- secret key `minioadmin123`

`tenant-credentials.yaml` defines the bootstrap credentials used to create the
checked-in tenant users:

- `MLFLOWTEAMA`
- `MLFLOWTEAMB`

Team workloads do not use the root credentials. They use namespace-local
`mlflow-s3-credentials` secrets under `teams/<team>/mlflow/`.

## Tenant Bootstrap

`tenant-bootstrap-job.yaml` is an Argo CD `PostSync` hook with
`HookSucceeded` delete policy. Successful hook jobs are removed after
completion. Each app sync re-runs the bootstrap job after the MinIO workload is
present.

`tenant-bootstrap-configmap.yaml` waits for MinIO readiness and then creates:

- bucket `mlflow-ml-team-a`
- bucket `mlflow-ml-team-b`
- policy `mlflow-ml-team-a-rw`
- policy `mlflow-ml-team-b-rw`
- user `MLFLOWTEAMA`
- user `MLFLOWTEAMB`

The bootstrap job is static in the current repo state. Adding another tenant
requires updating `tenant-bootstrap-configmap.yaml` and
`tenant-credentials.yaml`.

## Local Profile Defaults

- MinIO is single replica
- object data persists across cluster rebuilds while
  `${ROOT_DIR}/.local/minio-data` is retained
- `bootstrap/uninstall.sh` preserves local MinIO host data by default
- `./bootstrap/reset-minio-data.sh --force` clears the local MinIO host data

## Quick Checks

```bash
kubectl -n minio get deploy,job,svc,pvc
kubectl get pv minio-pv
kubectl -n minio get job,pod -l app.kubernetes.io/name=minio-tenant-bootstrap
```

## Related Paths

- `application.yaml`
- `manifests/deployment.yaml`
- `manifests/service.yaml`
- `manifests/pv.yaml`
- `manifests/pvc.yaml`
- `manifests/tenant-bootstrap-configmap.yaml`
- `manifests/tenant-bootstrap-job.yaml`
- `manifests/tenant-credentials.yaml`
