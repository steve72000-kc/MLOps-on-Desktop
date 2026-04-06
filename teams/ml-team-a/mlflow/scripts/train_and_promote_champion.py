#!/usr/bin/env python3
"""Train a sklearn model, register it, and promote it to champion in MLflow.

Flow:
1) Train a small KNN iris classifier.
2) Log a native sklearn/joblib artifact to MLflow.
3) Create a model version from the run artifact.
4) Write KServe intent tags that point storageUri to MinIO (s3://...).
5) Point alias (default: champion) to the new version.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile

try:
    import joblib
    import mlflow
    from mlflow import MlflowClient
except Exception as exc:  # pragma: no cover - dependency guard
    message = str(exc)
    if "Descriptors cannot be created directly" in message:
        raise SystemExit(
            "MLflow/protobuf dependency conflict detected.\n"
            "Fix in your current env:\n"
            "  pip install --upgrade 'mlflow==2.22.0' 'protobuf<4,>=3.20.3' scikit-learn joblib\n"
            "Or temporary workaround for one run:\n"
            "  PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python python3 train_and_promote_champion.py"
        ) from exc
    raise SystemExit(
        "Missing/invalid MLflow install. Install with:\n"
        "  pip install --upgrade 'mlflow==2.22.0' 'protobuf<4,>=3.20.3' scikit-learn joblib\n"
        "or if you prefer conda:\n"
        "   conda install -c conda-forge mlflow=2.22.0 protobuf=3.20.3 scikit-learn joblib"
    ) from exc

try:
    from sklearn.datasets import load_iris
    from sklearn.metrics import accuracy_score
    from sklearn.model_selection import train_test_split
    from sklearn.neighbors import KNeighborsClassifier
except Exception as exc:  # pragma: no cover - runtime dependency guard
    raise SystemExit(
        "Missing dependency: scikit-learn. Install with:\n"
        "  pip install --upgrade scikit-learn joblib\n"
        "or if you prefer conda:\n"
        "   conda install -c conda-forge scikit-learn joblib"
    ) from exc


DEFAULT_TRACKING_URI = "http://mlflow.ml-team-a.local"
DEFAULT_REGISTERED_MODEL = "prod.ml-team-a.sklearn-iris"
DEFAULT_ALIAS = "champion"
DEFAULT_EXPERIMENT = "team-a-iris-training"
DEFAULT_KSERVE_NAME = "sklearn-iris-v1"
DEFAULT_MODEL_ARTIFACT_PATH = "model"
DEFAULT_MODEL_FILENAME = "model.joblib"
DEFAULT_MINIO_ARTIFACT_ROOT = "s3://mlflow-ml-team-a/artifacts"

# Optional auth for environments where MLflow is protected.
DEFAULT_TRACKING_USERNAME = ""
DEFAULT_TRACKING_PASSWORD = ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train, register, and promote champion sklearn model in MLflow")
    parser.add_argument(
        "--tracking-uri",
        default=os.getenv("MLFLOW_TRACKING_URI", DEFAULT_TRACKING_URI),
        help="MLflow tracking URI",
    )
    parser.add_argument(
        "--registered-model",
        default=DEFAULT_REGISTERED_MODEL,
        help="Registered model name",
    )
    parser.add_argument(
        "--alias",
        default=DEFAULT_ALIAS,
        help="Model alias to set",
    )
    parser.add_argument(
        "--experiment",
        default=DEFAULT_EXPERIMENT,
        help="MLflow experiment name",
    )
    parser.add_argument(
        "--kserve-name",
        default=DEFAULT_KSERVE_NAME,
        help="InferenceService metadata.name to render",
    )
    parser.add_argument(
        "--model-artifact-path",
        default=DEFAULT_MODEL_ARTIFACT_PATH,
        help="Run artifact path for the logged model",
    )
    parser.add_argument(
        "--storage-uri",
        default="",
        help="Explicit KServe storageUri. If empty, computed from MinIO artifact root + run path.",
    )
    parser.add_argument(
        "--minio-artifact-root",
        default=os.getenv("MLFLOW_MINIO_ARTIFACT_ROOT", DEFAULT_MINIO_ARTIFACT_ROOT),
        help="Base MinIO artifact root (s3://...) used to build storageUri when --storage-uri is not set",
    )
    parser.add_argument(
        "--neighbors",
        type=int,
        default=3,
        help="Number of neighbors for KNN training",
    )
    return parser.parse_args()


def build_inline_intent(kserve_name: str, storage_uri: str) -> dict:
    return {
        "metadata": {
            "name": kserve_name,
            "labels": {
                "owner.team": "ml-team-a",
                # Required by kserve-mlserver-custom runtime template.
                "modelClass": "mlserver_sklearn.SKLearnModel",
            },
            "annotations": {
                "autoscaling.knative.dev/min-scale": "1",
                "autoscaling.knative.dev/max-scale": "2",
                "autoscaling.knative.dev/target": "10",
            },
        },
        "spec": {
            "predictor": {
                "model": {
                    "modelFormat": {"name": "sklearn", "version": "1"},
                    "runtime": "kserve-mlserver-custom",
                    "protocolVersion": "v2",
                    "storageUri": storage_uri,
                }
            }
        },
    }


def build_minio_storage_uri(
    minio_artifact_root: str,
    experiment_id: str,
    run_id: str,
    artifact_path: str,
) -> str:
    normalized_root = minio_artifact_root.rstrip("/")
    normalized_artifact_path = artifact_path.strip("/")
    if not normalized_root.startswith("s3://"):
        raise SystemExit(
            f"--minio-artifact-root must start with s3://, got: {minio_artifact_root!r}"
        )
    if not normalized_artifact_path:
        raise SystemExit("--model-artifact-path must not be empty")
    return f"{normalized_root}/{experiment_id}/{run_id}/artifacts/{normalized_artifact_path}"


def main() -> int:
    args = parse_args()

    if DEFAULT_TRACKING_USERNAME and "MLFLOW_TRACKING_USERNAME" not in os.environ:
        os.environ["MLFLOW_TRACKING_USERNAME"] = DEFAULT_TRACKING_USERNAME
    if DEFAULT_TRACKING_PASSWORD and "MLFLOW_TRACKING_PASSWORD" not in os.environ:
        os.environ["MLFLOW_TRACKING_PASSWORD"] = DEFAULT_TRACKING_PASSWORD

    mlflow.set_tracking_uri(args.tracking_uri)
    mlflow.set_experiment(args.experiment)

    features, labels = load_iris(return_X_y=True)
    x_train, x_test, y_train, y_test = train_test_split(
        features,
        labels,
        test_size=0.2,
        random_state=42,
        stratify=labels,
    )

    model = KNeighborsClassifier(n_neighbors=args.neighbors)
    model.fit(x_train, y_train)
    predictions = model.predict(x_test)
    accuracy = float(accuracy_score(y_test, predictions))

    with mlflow.start_run(run_name="iris-knn-train") as run:
        run_id = run.info.run_id
        experiment_id = str(run.info.experiment_id)
        artifact_path = args.model_artifact_path.strip("/")

        mlflow.log_param("model_type", "KNeighborsClassifier")
        mlflow.log_param("dataset", "iris")
        mlflow.log_param("neighbors", args.neighbors)
        mlflow.log_param("features", int(features.shape[1]))
        mlflow.log_param("train_rows", int(x_train.shape[0]))
        mlflow.log_param("test_rows", int(x_test.shape[0]))
        mlflow.log_metric("accuracy", accuracy)

        # Log a native sklearn/joblib artifact so KServe loads from MinIO-backed
        # storageUri instead of relying on the MLflow sklearn flavor serializer.
        with tempfile.TemporaryDirectory() as tmpdir:
            model_path = os.path.join(tmpdir, DEFAULT_MODEL_FILENAME)
            joblib.dump(model, model_path)
            mlflow.log_artifact(model_path, artifact_path=artifact_path)

    client = MlflowClient(tracking_uri=args.tracking_uri)

    try:
        client.create_registered_model(args.registered_model)
    except Exception:
        pass

    mv = client.create_model_version(
        name=args.registered_model,
        source=f"runs:/{run_id}/{artifact_path}/{DEFAULT_MODEL_FILENAME}",
        run_id=run_id,
    )
    version = str(mv.version)

    if args.storage_uri.strip():
        storage_uri = args.storage_uri.strip()
    else:
        storage_uri = build_minio_storage_uri(
            minio_artifact_root=args.minio_artifact_root,
            experiment_id=experiment_id,
            run_id=run_id,
            artifact_path=artifact_path,
        )

    intent = build_inline_intent(args.kserve_name, storage_uri)

    client.set_model_version_tag(args.registered_model, version, "kserve.intent.mode", "inline")
    client.set_model_version_tag(
        args.registered_model,
        version,
        "kserve.intent.payload",
        json.dumps(intent, separators=(",", ":")),
    )
    client.set_registered_model_alias(args.registered_model, args.alias, version)

    print(
        json.dumps(
            {
                "tracking_uri": args.tracking_uri,
                "registered_model": args.registered_model,
                "version": version,
                "alias": args.alias,
                "accuracy": accuracy,
                "neighbors": args.neighbors,
                "storage_uri": storage_uri,
                "model_format": "sklearn",
                "runtime": "kserve-mlserver-custom",
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
