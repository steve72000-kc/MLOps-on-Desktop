# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-04-05

### Added

- Initial public release.
- Local-first multi-tenant MLOps platform reference stack for laptop-scale use.
- GitOps-driven platform layout with Argo CD, team ownership boundaries, and tenant deployment targets.
- MLflow-driven deployment intent flow with workflow-based validation and Git writeback into tenant-safe KServe manifests.
- End-to-end local serving stack built around MLflow, KServe, Knative, Istio, and MinIO.
- Platform observability with Grafana, Prometheus, Loki, and troubleshooting documentation.
- Repository validation covering scripts, tests, and tracked Kustomize roots.
