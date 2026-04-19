# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0]

### Added

- cert-manager-backed Istio workload identity with `cert-manager-istio-csr`, explicit mesh root CA pinning from the public certificate only, and repo-managed strict mTLS by default with narrow local-profile permissive exceptions.

## [1.0.1] - 2026-04-12

### Added

- `make validate-container` for a clean-room, containerized validation run that mirrors CI more closely.

### Changed

- Pinned the CI validation `kubectl` download to a specific version for reproducible runs.
- Documented the containerized validation workflow in the repository README.

### Fixed

- Woodpecker validation no longer loses the `kubectl` version between command steps.
- Containerized validation now handles Git safe-directory checks when enumerating tracked `kustomization.yaml` files.
- Addressed or narrowly suppressed existing `shellcheck` warnings in bootstrap helper scripts so validation passes cleanly.

## [1.0.0] - 2026-04-05

### Added

- Initial public release.
- Local-first multi-tenant MLOps platform reference stack for laptop-scale use.
- GitOps-driven platform layout with Argo CD, team ownership boundaries, and tenant deployment targets.
- MLflow-driven deployment intent flow with workflow-based validation and Git writeback into tenant-safe KServe manifests.
- End-to-end local serving stack built around MLflow, KServe, Knative, Istio, and MinIO.
- Platform observability with Grafana, Prometheus, Loki, and troubleshooting documentation.
- Repository validation covering scripts, tests, and tracked Kustomize roots.
