# MLflow Base

Shared MLflow Helm values consumed by all team-specific MLflow apps.

Files:
- `values.yaml`: base values merged with each team's `teams/<team>/mlflow/values.yaml`.

Operational note:
- keep `extraArgs.workers` as a quoted string in values (`\"1\"`) to match chart schema expectations.
